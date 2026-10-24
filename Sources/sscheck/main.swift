import Foundation

// Assert-based self-check (swift-testing macros don't load on this Command Line Tools toolchain).
nonisolated(unsafe) var failures = 0

func check(_ condition: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) {
    do {
        if try !condition() { failures += 1; print("FAIL \(file):\(line)") }
    } catch {
        failures += 1; print("FAIL \(file):\(line) threw \(error)")
    }
}

func check<E: Error>(throws _: E.Type, file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Any) {
    do {
        _ = try body()
        failures += 1; print("FAIL \(file):\(line) did not throw")
    } catch is E {
    } catch {
        failures += 1; print("FAIL \(file):\(line) threw wrong error \(error)")
    }
}

let cases: [(String, () throws -> Void)] = [
    ("contains", SearchTests.containsIsCaseInsensitiveByDefault),
    ("caseSensitive", SearchTests.caseSensitive),
    ("prefixSuffixExact", SearchTests.prefixSuffixExact),
    ("andOr", SearchTests.andOrKeywords),
    ("regex", SearchTests.regex),
    ("unicode", SearchTests.unicodeNormalization),
    ("hidden", SearchTests.hiddenFiltering),
    ("kind", SearchTests.kindFilter),
    ("extension", SearchTests.extensionFilter),
    ("sizeDate", SearchTests.sizeAndDateFilters),
    ("location", SearchTests.locationFilter),
    ("emptyQuery", SearchTests.emptyQueryReturnsNothing),
    ("pathsSorting", SearchTests.pathsAndSorting),
    ("cancel", SearchTests.cancelledSearchReturnsEmpty),
    ("serialization", IndexTests.serializationRoundTrip),
    ("corruptData", IndexTests.corruptDataIsRejected),
    ("removeSubtrees", IndexTests.removeSubtreesMarksDescendants),
    ("crawl", CrawlerTests.crawlMatchesFileManager),
    ("liveIndex", CrawlerTests.liveIndexAppliesChanges),
]

for (name, run) in cases {
    let before = failures
    do { try run() } catch { failures += 1; print("FAIL \(name) threw \(error)") }
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}
print(failures == 0 ? "All \(cases.count) checks passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
