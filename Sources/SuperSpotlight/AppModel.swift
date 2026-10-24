import AppKit
import Combine
import SuperSpotlightCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum TimeFilter: String, CaseIterable, Identifiable {
        case all = "All time", hour = "Past hour", day = "Past 24 hours", week = "Past 7 days", month = "Past 30 days", year = "Past year"
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .all: nil
            case .hour: 3600
            case .day: 86400
            case .week: 7 * 86400
            case .month: 30 * 86400
            case .year: 365 * 86400
            }
        }
    }

    enum SizeUnit: String, CaseIterable, Identifiable {
        case mb = "MB", gb = "GB"
        var id: String { rawValue }
        var bytes: Double { self == .mb ? 1_048_576 : 1_073_741_824 }
    }

    static let extensionChips = ["txt", "pdf", "docx", "xlsx", "pptx"]

    // Search inputs; any change re-runs the search.
    @Published var text = "" { didSet { if text != oldValue { runSearch() } } }
    @Published var mode: SearchQuery.Mode = .contains { didSet { runSearch() } }
    @Published var caseSensitive = false { didSet { runSearch() } }
    @Published var kind: SearchQuery.Kind = .all { didSet { runSearch() } }
    @Published var chips: Set<String> = [] { didSet { runSearch() } }
    @Published var customExtensions = "" { didSet { runSearch() } }
    @Published var minSizeText = "" { didSet { runSearch() } }
    @Published var maxSizeText = "" { didSet { runSearch() } }
    @Published var sizeUnit: SizeUnit = .mb { didSet { runSearch() } }
    @Published var timeFilter: TimeFilter = .all { didSet { runSearch() } }
    /// Folder to search in (absolute path); nil searches the whole index.
    @Published var location: String? { didSet { runSearch() } }
    @Published var sortKey: SearchEngine.SortKey? { didSet { runSearch() } }
    @Published var ascending = true { didSet { runSearch() } }
    @Published var thumbnails = false

    // Outputs.
    @Published private(set) var index = FileIndex()
    @Published private(set) var results: [Int32] = []
    @Published private(set) var resultsVersion = 0
    @Published private(set) var searchStatus = "0 files found"
    @Published private(set) var searchError: String?
    @Published private(set) var indexStatus = ""
    @Published private(set) var hasFullDiskAccess = AppModel.checkFullDiskAccess()

    let settings = AppSettings.shared
    private var service: IndexService!
    private var token = CancelToken()
    private var bag: Set<AnyCancellable> = []

    private init() {
        service = IndexService { update in
            Task { @MainActor in AppModel.shared.apply(update) }
        }
        // Scope / exclusion changes need a fresh crawl; hidden toggle only re-filters.
        Publishers.CombineLatest(settings.$scope, settings.$excluded)
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.rebuildIndex() }
            .store(in: &bag)
        settings.$showHidden.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.runSearch() }
        }.store(in: &bag)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            ws.publisher(for: name).sink { [weak self] _ in
                guard let self, self.settings.scope == .allDisks else { return }
                self.rebuildIndex()
            }.store(in: &bag)
        }
    }

    func start() { service.start(config: settings.crawlConfig) }
    func rebuildIndex() { service.rebuild(config: settings.crawlConfig) }
    func saveIndex() { service.saveNow() }

    func refreshFullDiskAccess() { hasFullDiskAccess = Self.checkFullDiskAccess() }

    /// The TCC database is only readable with Full Disk Access.
    static func checkFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    private func apply(_ update: IndexService.Update) {
        indexStatus = update.status
        if let idx = update.index {
            index = idx
            runSearch(debounce: true)
        }
    }

    var query: SearchQuery {
        var q = SearchQuery()
        q.text = text
        q.mode = mode
        q.caseSensitive = caseSensitive
        q.kind = kind
        let custom = customExtensions.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty }
        q.extensions = Array(chips.union(custom)).sorted()
        q.minSize = Double(minSizeText).map { Int64($0 * sizeUnit.bytes) }
        q.maxSize = Double(maxSizeText).map { Int64($0 * sizeUnit.bytes) }
        q.modifiedAfter = timeFilter.seconds.map { Date().addingTimeInterval(-$0) }
        q.showHidden = settings.showHidden
        q.location = location
        return q
    }

    /// Runs the query off the main thread; a newer call cancels older ones.
    func runSearch(debounce: Bool = false) {
        token.cancel()
        let t = CancelToken()
        token = t
        let q = query, idx = index, sort = sortKey, asc = ascending
        guard q.hasCriteria else {
            setResults([], status: "0 files found", error: nil)
            return
        }
        Task.detached(priority: .userInitiated) {
            if debounce { try? await Task.sleep(for: .milliseconds(400)) }
            guard !t.isCancelled else { return }
            let t0 = Date()
            do {
                var ids = try SearchEngine.search(q, in: idx, cancel: t)
                if let sort { ids = SearchEngine.sorted(ids, by: sort, ascending: asc, in: idx) }
                let secs = Date().timeIntervalSince(t0)
                await MainActor.run {
                    guard !t.isCancelled else { return }
                    AppModel.shared.setResults(ids, status: String(format: "%@ files found (time %.3f sec)", ids.count.formatted(), secs), error: nil)
                }
            } catch {
                let message = error is SearchEngine.LocationNotIndexed
                    ? "That folder isn't in the index; check the search scope and excluded folders in Settings"
                    : "Invalid regular expression"
                await MainActor.run {
                    guard !t.isCancelled else { return }
                    AppModel.shared.setResults([], status: "0 files found", error: message)
                }
            }
        }
    }

    private func setResults(_ ids: [Int32], status: String, error: String?) {
        results = ids
        resultsVersion += 1
        searchStatus = status
        searchError = error
    }

    func url(_ id: Int32) -> URL { URL(fileURLWithPath: index.path(id)) }

    static let quickLocations: [(title: String, path: String)] = [
        ("Desktop", "~/Desktop"), ("Documents", "~/Documents"), ("Downloads", "~/Downloads"), ("Home", "~"), ("Applications", "/Applications"),
    ].map { ($0.0, ($0.1 as NSString).expandingTildeInPath) }

    var locationTitle: String {
        guard let location else { return "Everywhere" }
        return Self.quickLocations.first { $0.path == location }?.title ?? FileManager.default.displayName(atPath: location)
    }

    func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Search Here"
        if let location { panel.directoryURL = URL(fileURLWithPath: location) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        location = url.path
    }
}
