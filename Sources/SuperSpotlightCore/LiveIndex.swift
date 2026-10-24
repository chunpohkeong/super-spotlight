import Foundation

/// A `FileIndex` plus a directory path lookup, updated incrementally from changed paths.
public struct LiveIndex: Sendable {
    public private(set) var index: FileIndex
    public let config: CrawlConfig
    private var dirLookup: [String: Int32] = [:]

    public init(index: FileIndex, config: CrawlConfig) {
        self.index = index
        self.config = config
        var dirPaths = [String?](repeating: nil, count: index.count)
        for k in 0..<index.count {
            let i = Int32(k)
            guard index.isDirectory(i), !index.isRemoved(i) else { continue }
            let p = index.parent(i)
            let path: String
            if p < 0 { path = index.name(i) } else if let pp = dirPaths[Int(p)] { path = Crawler.join(pp, index.name(i)) } else { continue }
            dirPaths[k] = path
            dirLookup[path] = i
        }
    }

    /// Re-syncs the directories affected by the given changed paths (FSEvents item paths).
    /// Returns true if anything changed.
    @discardableResult
    public mutating func apply(changedPaths: [String]) -> Bool {
        var dirs = Set<Int32>()
        for raw in changedPaths {
            var path = Self.normalize(raw)
            if let d = dirLookup[path] { dirs.insert(d) }
            // Walk up to the nearest indexed directory; it gets rescanned one level deep.
            while true {
                let parent = (path as NSString).deletingLastPathComponent
                if parent == path || parent.isEmpty { break }
                path = parent
                if let d = dirLookup[path] { dirs.insert(d); break }
            }
        }
        return rescan(dirs)
    }

    static func normalize(_ raw: String) -> String {
        var p = raw
        // The boot volume's data side can be reported through its firmlinked location.
        let dataPrefix = "/System/Volumes/Data"
        if p.hasPrefix(dataPrefix + "/") { p.removeFirst(dataPrefix.count) }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private mutating func rescan(_ dirs: Set<Int32>) -> Bool {
        guard let first = dirs.min() else { return false }
        // Current children (by NFC name) of every directory being rescanned.
        var children: [Int32: [String: Int32]] = [:]
        for k in Int(first) + 1..<index.count {
            let i = Int32(k)
            let p = index.parent(i)
            if dirs.contains(p), !index.isRemoved(i) { children[p, default: [:]][index.name(i)] = i }
        }

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        var toRemove = Set<Int32>()
        let oldCount = index.count
        var changed = false

        for d in dirs.sorted() where !index.isRemoved(d) && !toRemove.contains(d) {
            let dPath = index.path(d)
            guard let listing = Crawler.listDirectory(dPath, buffer: buffer) else {
                if !FileManager.default.fileExists(atPath: dPath) { toRemove.insert(d) }
                continue
            }
            var existing = children[d] ?? [:]
            for e in listing {
                let key = e.name.precomposedStringWithCanonicalMapping
                if let i = existing.removeValue(forKey: key), index.isDirectory(i) == e.isDirectory {
                    if index.size(i) != e.size || index.mtimes[Int(i)] != e.mtime || index.isHidden(i) != e.hidden {
                        index.update(i, size: e.size, mtime: e.mtime, hidden: e.hidden)
                        changed = true
                    }
                    continue
                } else if let i = children[d]?[key] {
                    toRemove.insert(i)  // kind changed (file <-> directory)
                }
                if e.isDirectory {
                    let childPath = Crawler.join(dPath, e.name)
                    if config.isExcluded(directory: childPath, name: e.name) { continue }
                    let i = index.append(name: e.name, parent: d, isDirectory: true, hidden: e.hidden, size: 0, mtime: e.mtime)
                    if !e.dataless { Crawler.crawlChildren(of: i, path: childPath, into: &index, config: config, buffer: buffer) }
                } else {
                    index.append(name: e.name, parent: d, isDirectory: false, hidden: e.hidden, size: e.size, mtime: e.mtime)
                }
                changed = true
            }
            toRemove.formUnion(existing.values)
        }

        if !toRemove.isEmpty {
            changed = true
            let removedDirs = index.removeSubtrees(toRemove)
            if !removedDirs.isEmpty {
                let dead = Set(removedDirs)
                dirLookup = dirLookup.filter { !dead.contains($0.value) }
            }
        }
        for k in oldCount..<index.count {
            let i = Int32(k)
            if index.isDirectory(i), !index.isRemoved(i) { dirLookup[index.path(i)] = i }
        }
        return changed
    }
}
