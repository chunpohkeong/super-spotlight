import Foundation

/// Compact, append-only filename index. Entries are stored column-wise in flat arrays so
/// the whole index can be scanned quickly and copied cheaply (copy-on-write) as a snapshot.
///
/// Invariant: a child's index is always greater than its parent's index. Root entries have
/// `parent == -1` and store their full path as the name.
public struct FileIndex: Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let directory = Flags(rawValue: 1)
        public static let hidden = Flags(rawValue: 2)
        public static let removed = Flags(rawValue: 4)
    }

    var parents: [Int32] = []
    var flags: [UInt8] = []
    var sizes: [Int64] = []
    var mtimes: [Double] = []
    var nameStart: [UInt32] = []
    var nameLen: [UInt16] = []
    var foldStart: [UInt32] = []
    var foldLen: [UInt16] = []
    /// NFC-normalized UTF-8 names.
    var names: [UInt8] = []
    /// NFC-normalized, lowercased UTF-8 names (for case-insensitive matching).
    var folded: [UInt8] = []

    public init() {}

    public var count: Int { parents.count }

    @discardableResult
    public mutating func append(name: String, parent: Int32, isDirectory: Bool, hidden: Bool, size: Int64, mtime: Double) -> Int32 {
        let nfc = name.precomposedStringWithCanonicalMapping
        let raw = Array(nfc.utf8.prefix(Int(UInt16.max)))
        let fold = Array(nfc.lowercased().utf8.prefix(Int(UInt16.max)))
        let parentHidden = parent >= 0 && flags[Int(parent)] & Flags.hidden.rawValue != 0
        var f: Flags = []
        if isDirectory { f.insert(.directory) }
        if hidden || parentHidden { f.insert(.hidden) }
        parents.append(parent)
        flags.append(f.rawValue)
        sizes.append(isDirectory ? 0 : size)
        mtimes.append(mtime)
        nameStart.append(UInt32(names.count))
        nameLen.append(UInt16(raw.count))
        foldStart.append(UInt32(folded.count))
        foldLen.append(UInt16(fold.count))
        names.append(contentsOf: raw)
        folded.append(contentsOf: fold)
        return Int32(parents.count - 1)
    }

    public func parent(_ i: Int32) -> Int32 { parents[Int(i)] }
    public func isDirectory(_ i: Int32) -> Bool { flags[Int(i)] & Flags.directory.rawValue != 0 }
    public func isHidden(_ i: Int32) -> Bool { flags[Int(i)] & Flags.hidden.rawValue != 0 }
    public func isRemoved(_ i: Int32) -> Bool { flags[Int(i)] & Flags.removed.rawValue != 0 }
    public func size(_ i: Int32) -> Int64 { sizes[Int(i)] }
    public func modified(_ i: Int32) -> Date { Date(timeIntervalSince1970: mtimes[Int(i)]) }

    public func name(_ i: Int32) -> String {
        let s = Int(nameStart[Int(i)]), n = Int(nameLen[Int(i)])
        return names.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[s..<s + n]), as: UTF8.self) }
    }

    /// Lowercased extension without the dot, or "" when there is none.
    public func pathExtension(_ i: Int32) -> String {
        let s = Int(foldStart[Int(i)]), n = Int(foldLen[Int(i)])
        return folded.withUnsafeBufferPointer { buf in
            var j = s + n - 1
            while j > s, buf[j] != UInt8(ascii: ".") { j -= 1 }
            guard j > s, j < s + n - 1 else { return "" }
            return String(decoding: UnsafeBufferPointer(rebasing: buf[(j + 1)..<(s + n)]), as: UTF8.self)
        }
    }

    public func path(_ i: Int32) -> String {
        var parts: [String] = []
        var cur = i
        while cur >= 0 {
            parts.append(name(cur))
            cur = parents[Int(cur)]
        }
        var result = parts.removeLast()  // root holds a full path
        for p in parts.reversed() {
            if !result.hasSuffix("/") { result += "/" }
            result += p
        }
        return result
    }

    mutating func update(_ i: Int32, size: Int64, mtime: Double, hidden: Bool) {
        let k = Int(i)
        if flags[k] & Flags.directory.rawValue == 0 { sizes[k] = size }
        mtimes[k] = mtime
        let parentHidden = parents[k] >= 0 && flags[Int(parents[k])] & Flags.hidden.rawValue != 0
        if hidden || parentHidden { flags[k] |= Flags.hidden.rawValue } else { flags[k] &= ~Flags.hidden.rawValue }
    }

    /// Marks the given entries and all their descendants as removed. Returns removed directory ids.
    @discardableResult
    public mutating func removeSubtrees(_ ids: Set<Int32>) -> [Int32] {
        guard let first = ids.min() else { return [] }
        var removedDirs: [Int32] = []
        let removedBit = Flags.removed.rawValue
        for k in Int(first)..<parents.count {
            if flags[k] & removedBit != 0 { continue }
            let p = parents[k]
            if ids.contains(Int32(k)) || (p >= 0 && flags[Int(p)] & removedBit != 0) {
                flags[k] |= removedBit
                if flags[k] & Flags.directory.rawValue != 0 { removedDirs.append(Int32(k)) }
            }
        }
        return removedDirs
    }

    /// Id of the live directory at `path`, or nil when it isn't indexed.
    public func directoryID(atPath path: String) -> Int32? {
        var p = (path as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let dirBit = Flags.directory.rawValue, removedBit = Flags.removed.rawValue
        // Find the root that contains the path, then walk down one component at a time.
        var best: (id: Int32, rest: Substring)?
        for k in 0..<parents.count where parents[k] < 0 && flags[k] & removedBit == 0 {
            let root = name(Int32(k))
            let rest: Substring
            if p == root { rest = "" }
            else if root == "/" , p.hasPrefix("/") { rest = p.dropFirst() }
            else if p.hasPrefix(root + "/") { rest = p.dropFirst(root.count + 1) }
            else { continue }
            if best == nil || rest.count < best!.rest.count { best = (Int32(k), rest) }
        }
        guard let found = best else { return nil }
        var cur = found.id
        let rest = found.rest
        for component in rest.split(separator: "/") {
            var next: Int32?
            for k in Int(cur) + 1..<parents.count where parents[k] == cur && flags[k] & dirBit != 0 && flags[k] & removedBit == 0 {
                if name(Int32(k)) == component { next = Int32(k); break }
            }
            guard let n = next else { return nil }
            cur = n
        }
        return cur
    }

    /// Per-entry flag (1/0): is the entry strictly inside directory `dir`?
    func descendantMask(of dir: Int32) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: parents.count)
        mask[Int(dir)] = 2  // marks the folder itself as an ancestor without matching it
        for k in Int(dir) + 1..<parents.count {
            let p = parents[k]
            if p >= 0 && mask[Int(p)] != 0 { mask[k] = 1 }
        }
        mask[Int(dir)] = 0
        return mask
    }

    public struct Counts: Sendable, Equatable {
        public var files: Int
        public var directories: Int
    }

    public func counts() -> Counts {
        var c = Counts(files: 0, directories: 0)
        for f in flags where f & Flags.removed.rawValue == 0 {
            if f & Flags.directory.rawValue != 0 { c.directories += 1 } else { c.files += 1 }
        }
        return c
    }
}

// MARK: - Persistence

extension FileIndex {
    static let magic: UInt32 = 0x5353_4958  // "SSIX"
    static let formatVersion: UInt32 = 1

    /// Serializes the index plus caller metadata (FSEvents id and config key), compressed with LZFSE.
    public func serialized(eventID: UInt64, configKey: String) throws -> Data {
        var w = Data()
        w.appendPOD(Self.magic)
        w.appendPOD(Self.formatVersion)
        w.appendPOD(eventID)
        let key = Array(configKey.utf8)
        w.appendPOD(UInt32(key.count))
        w.append(contentsOf: key)
        w.appendArray(parents)
        w.appendArray(flags)
        w.appendArray(sizes)
        w.appendArray(mtimes)
        w.appendArray(nameStart)
        w.appendArray(nameLen)
        w.appendArray(foldStart)
        w.appendArray(foldLen)
        w.appendArray(names)
        w.appendArray(folded)
        return try (w as NSData).compressed(using: .lzfse) as Data
    }

    public struct DecodeError: Error {}

    public static func deserialize(_ data: Data) throws -> (index: FileIndex, eventID: UInt64, configKey: String) {
        let raw = try (data as NSData).decompressed(using: .lzfse) as Data
        var r = Reader(data: raw)
        guard try r.pod(UInt32.self) == magic, try r.pod(UInt32.self) == formatVersion else { throw DecodeError() }
        let eventID = try r.pod(UInt64.self)
        let keyLen = Int(try r.pod(UInt32.self))
        let key = String(decoding: try r.bytes(keyLen), as: UTF8.self)
        var idx = FileIndex()
        idx.parents = try r.array()
        idx.flags = try r.array()
        idx.sizes = try r.array()
        idx.mtimes = try r.array()
        idx.nameStart = try r.array()
        idx.nameLen = try r.array()
        idx.foldStart = try r.array()
        idx.foldLen = try r.array()
        idx.names = try r.array()
        idx.folded = try r.array()
        let n = idx.parents.count
        guard [idx.flags.count, idx.sizes.count, idx.mtimes.count, idx.nameStart.count, idx.nameLen.count,
               idx.foldStart.count, idx.foldLen.count].allSatisfy({ $0 == n }),
              n == 0 || (Int(idx.nameStart[n - 1]) + Int(idx.nameLen[n - 1]) <= idx.names.count
                  && Int(idx.foldStart[n - 1]) + Int(idx.foldLen[n - 1]) <= idx.folded.count),
              idx.parents.enumerated().allSatisfy({ $0.element < Int32($0.offset) })
        else { throw DecodeError() }
        return (idx, eventID, key)
    }

    private struct Reader {
        let data: Data
        var pos = 0
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, pos + n <= data.count else { throw DecodeError() }
            defer { pos += n }
            return data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + n))
        }
        mutating func pod<T>(_: T.Type) throws -> T {
            try bytes(MemoryLayout<T>.size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
        mutating func array<T>() throws -> [T] {
            guard let n = Int(exactly: try pod(UInt64.self)) else { throw DecodeError() }
            let (len, overflow) = n.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
            guard !overflow else { throw DecodeError() }
            let b = try bytes(len)
            return [T](unsafeUninitializedCapacity: n) { buf, count in
                b.withUnsafeBytes { src in
                    UnsafeMutableRawBufferPointer(buf).copyMemory(from: src)
                }
                count = n
            }
        }
    }
}

private extension Data {
    mutating func appendPOD<T>(_ v: T) {
        Swift.withUnsafeBytes(of: v) { append(contentsOf: $0) }
    }
    mutating func appendArray<T>(_ a: [T]) {
        appendPOD(UInt64(a.count))
        a.withUnsafeBytes { append(contentsOf: $0) }
    }
}
