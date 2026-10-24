import Foundation

import SuperSpotlightCore

/// root/
///   Report Final.PDF (2 MB)
///   notes.txt
///   .secret.txt
///   Projects/
///     main.swift
///     Readme.md
///   Café.txt   (stored decomposed, searched precomposed)
func sampleIndex() -> FileIndex {
    var idx = FileIndex()
    let now = Date().timeIntervalSince1970
    let root = idx.append(name: "/root", parent: -1, isDirectory: true, hidden: false, size: 0, mtime: now)
    idx.append(name: "Report Final.PDF", parent: root, isDirectory: false, hidden: false, size: 2_000_000, mtime: now - 10 * 86400)
    idx.append(name: "notes.txt", parent: root, isDirectory: false, hidden: false, size: 100, mtime: now - 3600)
    idx.append(name: ".secret.txt", parent: root, isDirectory: false, hidden: true, size: 5, mtime: now)
    let proj = idx.append(name: "Projects", parent: root, isDirectory: true, hidden: false, size: 0, mtime: now)
    idx.append(name: "main.swift", parent: proj, isDirectory: false, hidden: false, size: 300, mtime: now)
    idx.append(name: "Readme.md", parent: proj, isDirectory: false, hidden: false, size: 50, mtime: now)
    idx.append(name: "Cafe\u{301}.txt", parent: root, isDirectory: false, hidden: false, size: 1, mtime: now)
    return idx
}

func names(_ q: SearchQuery, _ idx: FileIndex = sampleIndex()) throws -> Set<String> {
    Set(try SearchEngine.search(q, in: idx).map { idx.name($0) })
}

func query(_ text: String, _ configure: (inout SearchQuery) -> Void = { _ in }) -> SearchQuery {
    var q = SearchQuery()
    q.text = text
    configure(&q)
    return q
}

enum SearchTests {
    static func containsIsCaseInsensitiveByDefault() throws {
        check(try names(query("report")) == ["Report Final.PDF"])
        check(try names(query("re")) == ["Report Final.PDF", "Readme.md"])
    }

    static func caseSensitive() throws {
        check(try names(query("re") { $0.caseSensitive = true }) == [])
        check(try names(query("Re") { $0.caseSensitive = true }) == ["Report Final.PDF", "Readme.md"])
    }

    static func prefixSuffixExact() throws {
        check(try names(query("read") { $0.mode = .prefix }) == ["Readme.md"])
        check(try names(query(".md") { $0.mode = .suffix }) == ["Readme.md"])
        check(try names(query("notes.txt") { $0.mode = .exact }) == ["notes.txt"])
        check(try names(query("notes") { $0.mode = .exact }) == [])
    }

    static func andOrKeywords() throws {
        check(try names(query("report pdf")) == ["Report Final.PDF"])
        check(try names(query("report swift")) == [])
        check(try names(query("main|notes")) == ["main.swift", "notes.txt"])
    }

    static func regex() throws {
        check(try names(query("^r.*\\.md$") { $0.mode = .regex }) == ["Readme.md"])
        check(throws: SearchEngine.InvalidRegex.self) { try names(query("(") { $0.mode = .regex }) }
    }

    static func unicodeNormalization() throws {
        check(try names(query("café")) == ["Café.txt"])
    }

    static func hiddenFiltering() throws {
        check(try names(query("secret")) == [])
        check(try names(query("secret") { $0.showHidden = true }) == [".secret.txt"])
    }

    static func kindFilter() throws {
        check(try names(query("pro") { $0.kind = .folders }) == ["Projects"])
        check(try names(query("pro") { $0.kind = .files }) == [])
    }

    static func extensionFilter() throws {
        check(try names(query("") { $0.extensions = ["pdf", "md"] }) == ["Report Final.PDF", "Readme.md"])
    }

    static func sizeAndDateFilters() throws {
        check(try names(query("") { $0.minSize = 1_000_000 }) == ["Report Final.PDF"])
        check(try names(query("t") { $0.maxSize = 100 }) == ["notes.txt", "Café.txt"])
        check(try names(query("") { $0.modifiedAfter = Date().addingTimeInterval(-2 * 3600); $0.extensions = ["txt"] })
            == ["notes.txt", "Café.txt"])
    }

    static func locationFilter() throws {
        check(try names(query("") { $0.location = "/root/Projects" }) == ["main.swift", "Readme.md"])
        check(try names(query("read") { $0.location = "/root/Projects/" }) == ["Readme.md"])
        check(try names(query("txt") { $0.location = "/root" }) == ["notes.txt", "Café.txt"])
        check(try names(query("pro") { $0.location = "/root/Projects" }) == [])  // the folder itself is not a result
        check(throws: SearchEngine.LocationNotIndexed.self) { try names(query("") { $0.location = "/root/nope" }) }
        check(throws: SearchEngine.LocationNotIndexed.self) { try names(query("") { $0.location = "/elsewhere" }) }
    }

    static func emptyQueryReturnsNothing() throws {
        check(try names(query("  ")) == [])
    }

    static func pathsAndSorting() {
        let idx = sampleIndex()
        let main = (0..<Int32(idx.count)).first { idx.name($0) == "main.swift" }!
        check(idx.path(main) == "/root/Projects/main.swift")
        check(idx.pathExtension(main) == "swift")
        let all = try! SearchEngine.search(query("") { $0.extensions = ["txt", "md", "swift"] }, in: idx)
        let bySize = SearchEngine.sorted(all, by: .size, ascending: false, in: idx).map { idx.name($0) }
        check(bySize.first == "main.swift")
    }

    static func cancelledSearchReturnsEmpty() throws {
        let token = CancelToken()
        token.cancel()
        check(try SearchEngine.search(query("e"), in: sampleIndex(), cancel: token).isEmpty)
    }
}

enum IndexTests {
    static func serializationRoundTrip() throws {
        var idx = sampleIndex()
        idx.removeSubtrees([4])  // Projects and its children
        let data = try idx.serialized(eventID: 42, configKey: "key")
        let (back, eventID, key) = try FileIndex.deserialize(data)
        check(eventID == 42 && key == "key")
        check(back.count == idx.count)
        for i in 0..<Int32(idx.count) {
            check(back.path(i) == idx.path(i))
            check(back.isRemoved(i) == idx.isRemoved(i))
            check(back.size(i) == idx.size(i))
        }
        check(back.counts().files == 4 && back.counts().directories == 1)
    }

    static func corruptDataIsRejected() {
        check(throws: (any Error).self) { try FileIndex.deserialize(Data("garbage".utf8)) }
    }

    static func removeSubtreesMarksDescendants() {
        var idx = sampleIndex()
        let dirs = idx.removeSubtrees([4])
        check(dirs == [4])
        check(idx.isRemoved(5) && idx.isRemoved(6) && !idx.isRemoved(1))
    }
}

enum CrawlerTests {
    static func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ss-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("skip/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try Data(count: 1234).write(to: root.appendingPathComponent("a/file1.txt"))
        try Data().write(to: root.appendingPathComponent("a/b/c/file2.md"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("skip/deep/nope.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("a"))
        return root.resolvingSymlinksInPath()
    }

    static func paths(_ idx: FileIndex) -> Set<String> {
        Set((0..<Int32(idx.count)).filter { !idx.isRemoved($0) }.map { idx.path($0) })
    }

    static func crawlMatchesFileManager() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CrawlConfig(roots: [root.path], excluded: [root.path + "/skip", "node_modules"])
        let idx = Crawler.buildIndex(config: config)
        let p = root.path
        check(paths(idx) == [p, "\(p)/a", "\(p)/a/b", "\(p)/a/b/c", "\(p)/a/file1.txt", "\(p)/a/b/c/file2.md",
                                "\(p)/.hidden", "\(p)/link"])
        let file1 = (0..<Int32(idx.count)).first { idx.name($0) == "file1.txt" }!
        check(idx.size(file1) == 1234)
        let hidden = (0..<Int32(idx.count)).first { idx.name($0) == ".hidden" }!
        check(idx.isHidden(hidden))
        let link = (0..<Int32(idx.count)).first { idx.name($0) == "link" }!
        check(!idx.isDirectory(link))
    }

    static func liveIndexAppliesChanges() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let p = root.path
        let config = CrawlConfig(roots: [p], excluded: ["node_modules", p + "/skip"])
        var live = LiveIndex(index: Crawler.buildIndex(config: config), config: config)

        // Create a file, a new nested directory, delete a directory, modify a file.
        try Data().write(to: root.appendingPathComponent("a/new.txt"))
        try fm.createDirectory(at: root.appendingPathComponent("a/fresh/inner"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("a/fresh/inner/deep.txt"))
        try fm.removeItem(at: root.appendingPathComponent("a/b"))
        try Data(count: 99).write(to: root.appendingPathComponent("a/file1.txt"))

        let changed = live.apply(changedPaths: ["\(p)/a/new.txt", "\(p)/a/fresh/inner/deep.txt", "\(p)/a/b", "\(p)/a/file1.txt"])
        check(changed)
        check(paths(live.index) == [p, "\(p)/a", "\(p)/a/file1.txt", "\(p)/a/new.txt", "\(p)/a/fresh",
                                      "\(p)/a/fresh/inner", "\(p)/a/fresh/inner/deep.txt", "\(p)/.hidden", "\(p)/link"])
        let file1 = (0..<Int32(live.index.count)).first { live.index.name($0) == "file1.txt" }!
        check(live.index.size(file1) == 99)

        // A second round uses the updated directory lookup.
        try Data().write(to: root.appendingPathComponent("a/fresh/inner/more.txt"))
        live.apply(changedPaths: ["\(p)/a/fresh/inner/more.txt"])
        check(paths(live.index).contains("\(p)/a/fresh/inner/more.txt"))
        let changedAgain = live.apply(changedPaths: ["\(p)/a/fresh/inner/more.txt"])
        check(!changedAgain)
    }
}
