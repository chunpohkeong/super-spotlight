import Foundation
import os

public struct SearchQuery: Sendable, Equatable {
    public enum Mode: String, CaseIterable, Sendable { case contains, prefix, suffix, exact, regex }
    public enum Kind: String, CaseIterable, Sendable { case all, files, folders }

    public var text = ""
    public var mode: Mode = .contains
    public var caseSensitive = false
    public var kind: Kind = .all
    /// Lowercased extensions without the dot; empty means any.
    public var extensions: [String] = []
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modifiedAfter: Date?
    public var showHidden = false
    /// Only entries inside this folder (absolute path, "~" allowed); nil means everywhere.
    public var location: String?

    public init() {}

    /// False when the query would simply list the whole index.
    public var hasCriteria: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !extensions.isEmpty || minSize != nil
            || maxSize != nil || modifiedAfter != nil || location != nil
    }

    /// "a b|c" -> [[a, b], [c]]: spaces are AND, "|" is OR.
    var groups: [[String]] {
        text.split(separator: "|").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
    }
}

public final class CancelToken: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func cancel() { flag.withLock { $0 = true } }
    public var isCancelled: Bool { flag.withLock { $0 } }
}

public enum SearchEngine {
    public struct InvalidRegex: Error {}
    /// The location folder is not part of the index (outside the scope, excluded, or missing).
    public struct LocationNotIndexed: Error {}

    /// Returns matching entry ids in index order. Empty when cancelled.
    public static func search(_ q: SearchQuery, in index: FileIndex, cancel: CancelToken = CancelToken()) throws -> [Int32] {
        guard q.hasCriteria else { return [] }
        let matcher = try Matcher(q)
        let n = index.count
        var mask: [UInt8]?
        if let location = q.location {
            guard let dir = index.directoryID(atPath: location) else { throw LocationNotIndexed() }
            mask = index.descendantMask(of: dir)
        }
        let scope = mask
        let chunk = 32_768
        let chunks = (n + chunk - 1) / chunk
        var parts = [[Int32]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { out in
            let out = UnsafeSendable(out)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                if cancel.isCancelled { return }
                let lo = c * chunk, hi = min(n, lo + chunk)
                out.value[c] = matcher.scan(index, lo..<hi, scope: scope)
            }
        }
        if cancel.isCancelled { return [] }
        return Array(parts.joined())
    }

    struct Matcher: Sendable {
        let q: SearchQuery
        /// All terms back to back; `termRanges[i]` locates term i, `groupEnds` closes each OR group.
        let termBytes: [UInt8]
        let termRanges: [Range<Int>]
        let groupEnds: [Int]
        let extensions: [[UInt8]]
        let regex: NSRegularExpression?
        let mtimeMin: Double?

        init(_ q: SearchQuery) throws {
            self.q = q
            var bytes: [UInt8] = [], ranges: [Range<Int>] = [], ends: [Int] = []
            if q.mode != .regex {
                for group in q.groups {
                    for term in group {
                        let s = term.precomposedStringWithCanonicalMapping
                        let b = Array((q.caseSensitive ? s : s.lowercased()).utf8)
                        ranges.append(bytes.count..<bytes.count + b.count)
                        bytes += b
                    }
                    ends.append(ranges.count)
                }
            }
            termBytes = bytes
            termRanges = ranges
            groupEnds = ends
            extensions = q.extensions.map { Array(("." + $0.lowercased()).utf8) }
            if q.mode == .regex, !q.text.isEmpty {
                guard let r = try? NSRegularExpression(pattern: q.text, options: q.caseSensitive ? [] : [.caseInsensitive])
                else { throw InvalidRegex() }
                regex = r
            } else {
                regex = nil
            }
            mtimeMin = q.modifiedAfter?.timeIntervalSince1970
        }

        func scan(_ index: FileIndex, _ range: Range<Int>, scope: [UInt8]? = nil) -> [Int32] {
            var out: [Int32] = []
            let removed = FileIndex.Flags.removed.rawValue, dirBit = FileIndex.Flags.directory.rawValue
            let hiddenBit = FileIndex.Flags.hidden.rawValue
            let mode = q.mode, kind = q.kind, showHidden = q.showHidden, caseSensitive = q.caseSensitive
            let minSize = q.minSize, maxSize = q.maxSize, mtimeMin = mtimeMin
            let hasTerms = !groupEnds.isEmpty, hasExtensions = !extensions.isEmpty
            let hasScope = scope != nil, scopeMask = scope ?? []
            index.flags.withUnsafeBufferPointer { flags in
            index.parents.withUnsafeBufferPointer { parents in
            index.sizes.withUnsafeBufferPointer { sizes in
            index.mtimes.withUnsafeBufferPointer { mtimes in
            index.nameStart.withUnsafeBufferPointer { nameStart in
            index.nameLen.withUnsafeBufferPointer { nameLen in
            index.foldStart.withUnsafeBufferPointer { foldStart in
            index.foldLen.withUnsafeBufferPointer { foldLen in
            index.names.withUnsafeBufferPointer { names in
            index.folded.withUnsafeBufferPointer { folded in
            termBytes.withUnsafeBufferPointer { terms in
            termRanges.withUnsafeBufferPointer { ranges in
            groupEnds.withUnsafeBufferPointer { ends in
            scopeMask.withUnsafeBufferPointer { inScope in
                for k in range {
                    if hasScope, inScope[k] == 0 { continue }
                    let f = flags[k]
                    if f & removed != 0 || parents[k] < 0 { continue }
                    if !showHidden, f & hiddenBit != 0 { continue }
                    let isDir = f & dirBit != 0
                    switch kind {
                    case .files: if isDir { continue }
                    case .folders: if !isDir { continue }
                    case .all: break
                    }
                    if let lo = minSize, isDir || sizes[k] < lo { continue }
                    if let hi = maxSize, isDir || sizes[k] > hi { continue }
                    if let m = mtimeMin, mtimes[k] < m { continue }
                    let fold = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(folded)[Int(foldStart[k])..<Int(foldStart[k]) + Int(foldLen[k])])
                    if hasExtensions {
                        if isDir || !extensions.contains(where: { e in e.withUnsafeBytes { Self.hasSuffix(fold, $0) } }) { continue }
                    }
                    if let regex {
                        let ns = Int(nameStart[k])
                        let s = String(decoding: UnsafeBufferPointer(rebasing: names[ns..<ns + Int(nameLen[k])]), as: UTF8.self)
                        if regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil { continue }
                    } else if hasTerms {
                        let name = caseSensitive
                            ? UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(names)[Int(nameStart[k])..<Int(nameStart[k]) + Int(nameLen[k])])
                            : fold
                        var matched = false, t = 0
                        for end in ends {
                            var all = true
                            while t < end {
                                if all, !Self.matches(name, UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(terms)[ranges[t]]), mode) { all = false }
                                t += 1
                            }
                            if all { matched = true; break }
                        }
                        if !matched { continue }
                    }
                    out.append(Int32(k))
                }
            }}}}}}}}}}}}}}
            return out
        }

        @inline(__always)
        static func matches(_ name: UnsafeRawBufferPointer, _ term: UnsafeRawBufferPointer, _ mode: SearchQuery.Mode) -> Bool {
            switch mode {
            case .contains:
                if term.isEmpty { return true }
                return term.count <= name.count && memmem(name.baseAddress, name.count, term.baseAddress, term.count) != nil
            case .prefix: return hasPrefix(name, term)
            case .suffix: return hasSuffix(name, term)
            case .exact: return name.count == term.count && hasPrefix(name, term)
            case .regex: return true
            }
        }

        @inline(__always)
        static func hasPrefix(_ hay: UnsafeRawBufferPointer, _ p: UnsafeRawBufferPointer) -> Bool {
            p.count <= hay.count && (p.isEmpty || memcmp(hay.baseAddress, p.baseAddress, p.count) == 0)
        }

        @inline(__always)
        static func hasSuffix(_ hay: UnsafeRawBufferPointer, _ s: UnsafeRawBufferPointer) -> Bool {
            s.count <= hay.count && (s.isEmpty || memcmp(hay.baseAddress! + (hay.count - s.count), s.baseAddress, s.count) == 0)
        }
    }

    // MARK: - Sorting

    public enum SortKey: String, Sendable { case name, path, size, kind, modified }

    public static func sorted(_ ids: [Int32], by key: SortKey, ascending: Bool, in index: FileIndex) -> [Int32] {
        func order<T: Comparable>(_ keyOf: (Int32) -> T) -> [Int32] {
            let keyed = ids.map { ($0, keyOf($0)) }
            return keyed.sorted { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }.map(\.0)
        }
        switch key {
        case .name: return order { index.name($0).lowercased() }
        case .path: return order { index.path($0).lowercased() }
        case .size: return order { index.size($0) }
        case .kind: return order { index.isDirectory($0) ? "" : index.pathExtension($0) }
        case .modified: return order { index.mtimes[Int($0)] }
        }
    }
}

struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
