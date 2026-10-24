import Foundation
import SuperSpotlightCore

// Usage: ssbench [root]   (default: home folder)
let root = CommandLine.arguments.dropFirst().first ?? NSHomeDirectory()
let config = CrawlConfig(roots: [root], excluded: ["~/Library/Caches", ".Trash"])

let t0 = Date()
let index = Crawler.buildIndex(config: config)
let crawl = Date().timeIntervalSince(t0)
let c = index.counts()
print(String(format: "Indexed %d entries (%d files, %d folders) in %.2f s = %.0f entries/s",
             index.count, c.files, c.directories, crawl, Double(index.count) / crawl))

let t1 = Date()
let data = try index.serialized(eventID: 0, configKey: config.key)
_ = try FileIndex.deserialize(data)
print(String(format: "Serialize + load: %.2f s, %.1f MB on disk", Date().timeIntervalSince(t1), Double(data.count) / 1_048_576))

func bench(_ label: String, _ configure: (inout SearchQuery) -> Void) throws {
    var q = SearchQuery()
    configure(&q)
    var best = Double.infinity, hits = 0
    for _ in 0..<5 {
        let t = Date()
        hits = try SearchEngine.search(q, in: index).count
        best = min(best, Date().timeIntervalSince(t))
    }
    print(String(format: "%-28@ %8d hits  %7.2f ms (best of 5)", label as NSString, hits, best * 1000))
}

try bench("contains \"a\"") { $0.text = "a" }
try bench("contains \"report\"") { $0.text = "report" }
try bench("AND \"swift test\"") { $0.text = "swift test" }
try bench("OR \"png|jpg\"") { $0.text = "png|jpg" }
try bench("prefix \"read\"") { $0.text = "read"; $0.mode = .prefix }
try bench("ext pdf, >1 MB") { $0.extensions = ["pdf"]; $0.minSize = 1_048_576 }
try bench("regex \"^IMG_\\d+\"") { $0.text = "^IMG_\\d+"; $0.mode = .regex }
