import Darwin
import Foundation

/// What to index. Entries in `excluded` that start with "/" are absolute directory paths;
/// any other entry matches a directory name anywhere (e.g. "node_modules").
public struct CrawlConfig: Sendable, Hashable {
    public var roots: [String]
    public var excluded: [String]

    public init(roots: [String], excluded: [String]) {
        self.roots = roots.map(CrawlConfig.expand)
        let ex = excluded.map(CrawlConfig.expand)
        self.excluded = ex
        excludedPaths = Set(ex.filter { $0.hasPrefix("/") })
        excludedNames = Set(ex.filter { !$0.hasPrefix("/") })
    }

    private let excludedPaths: Set<String>
    private let excludedNames: Set<String>

    /// Identifies the config in a persisted index; a different key forces a rebuild.
    public var key: String { roots.joined(separator: "\u{1}") + "\u{2}" + excluded.sorted().joined(separator: "\u{1}") }

    public func isExcluded(directory path: String, name: String) -> Bool {
        excludedNames.contains(name) || excludedPaths.contains(path)
    }

    static func expand(_ s: String) -> String {
        var p = (s.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

public enum Crawler {
    struct RawEntry {
        var name: String
        var isDirectory: Bool
        var size: Int64
        var mtime: Double
        var hidden: Bool
        /// Cloud placeholder (File Provider); listing it would block on a network fetch.
        var dataless = false
    }

    public static func buildIndex(config: CrawlConfig, isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in }) -> FileIndex {
        var index = FileIndex()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        for root in config.roots {
            var st = stat()
            guard stat(root, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            let r = index.append(name: root, parent: -1, isDirectory: true, hidden: false, size: 0,
                                 mtime: Double(st.st_mtimespec.tv_sec))
            crawlChildren(of: r, path: root, into: &index, config: config, buffer: buffer, isCancelled: isCancelled, progress: progress)
            if isCancelled() { break }
        }
        return index
    }

    /// Recursively appends everything below the directory entry `dir` located at `path`.
    static func crawlChildren(of dir: Int32, path: String, into index: inout FileIndex, config: CrawlConfig,
                              buffer: UnsafeMutableRawBufferPointer,
                              isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in }) {
        var stack: [(Int32, String)] = [(dir, path)]
        var lastReport = index.count
        while let (d, dPath) = stack.popLast() {
            if isCancelled() { return }
            guard let entries = listDirectory(dPath, buffer: buffer) else { continue }
            for e in entries {
                if e.isDirectory {
                    let childPath = join(dPath, e.name)
                    if config.isExcluded(directory: childPath, name: e.name) { continue }
                    let i = index.append(name: e.name, parent: d, isDirectory: true, hidden: e.hidden, size: 0, mtime: e.mtime)
                    if !e.dataless { stack.append((i, childPath)) }
                } else {
                    index.append(name: e.name, parent: d, isDirectory: false, hidden: e.hidden, size: e.size, mtime: e.mtime)
                }
            }
            if index.count - lastReport >= 20_000 {
                lastReport = index.count
                progress(index.count)
            }
        }
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    // Attribute bits from <sys/attr.h>, spelled out because some don't import as Swift constants.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileDataLength: UInt32 = 0x0000_0200
    private static let vDir: UInt32 = 2
    private static let ufHidden: UInt32 = 0x0000_8000
    private static let sfDataless: UInt32 = 0x4000_0000

    /// Lists one directory with getattrlistbulk(2). Returns nil if it can't be opened.
    /// Symlinks are reported as files and never followed.
    static func listDirectory(_ path: String, buffer: UnsafeMutableRawBufferPointer) -> [RawEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnModTime | cmnFlags
        al.fileattr = fileDataLength

        var result: [RawEntry] = []
        while true {
            let n = getattrlistbulk(fd, &al, buffer.baseAddress, buffer.count, 0)
            if n <= 0 { break }
            var entry = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var p = entry + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                var err: UInt32 = 0
                if returned.commonattr & cmnError != 0 { err = p.loadUnaligned(as: UInt32.self); p += 4 }
                var name = ""
                if returned.commonattr & cmnName != 0 {
                    let ref = p.loadUnaligned(as: attrreference_t.self)
                    let start = (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
                    let len = max(0, Int(ref.attr_length) - 1)  // length includes the NUL
                    name = String(decoding: UnsafeBufferPointer(start: start, count: len), as: UTF8.self)
                    p += MemoryLayout<attrreference_t>.size
                }
                var objType: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 { objType = p.loadUnaligned(as: UInt32.self); p += 4 }
                var mtime = 0.0
                if returned.commonattr & cmnModTime != 0 {
                    let ts = p.loadUnaligned(as: timespec.self)
                    mtime = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
                    p += MemoryLayout<timespec>.size
                }
                var bsdFlags: UInt32 = 0
                if returned.commonattr & cmnFlags != 0 { bsdFlags = p.loadUnaligned(as: UInt32.self); p += 4 }
                var size: Int64 = 0
                if returned.fileattr & fileDataLength != 0 { size = p.loadUnaligned(as: Int64.self) }
                entry += length

                guard err == 0, !name.isEmpty else { continue }
                result.append(RawEntry(name: name, isDirectory: objType == vDir, size: size, mtime: mtime,
                                       hidden: name.hasPrefix(".") || bsdFlags & ufHidden != 0,
                                       dataless: bsdFlags & sfDataless != 0))
            }
        }
        return result
    }
}
