import Foundation
import os
import SuperSpotlightCore

/// Owns the live index on a private serial queue: crawling, FSEvents updates and persistence.
/// Every change is pushed out as an immutable `FileIndex` snapshot through `onUpdate`.
final class IndexService: @unchecked Sendable {
    struct Update: Sendable {
        /// nil when only the status text changed.
        var index: FileIndex?
        var status: String
    }

    private struct Snapshot: Sendable {
        var index: FileIndex
        var eventID: UInt64
        var key: String
    }

    private let queue = DispatchQueue(label: "SuperSpotlight.index", qos: .userInitiated)
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let unsaved = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)
    private let saveLock = OSAllocatedUnfairLock()
    private let onUpdate: @Sendable (Update) -> Void

    // Confined to `queue`.
    private var live: LiveIndex?
    private var watcher: FSEventsWatcher?
    private var lastEventID: UInt64 = 0
    private var saveScheduled = false

    init(onUpdate: @escaping @Sendable (Update) -> Void) {
        self.onUpdate = onUpdate
    }

    static let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperSpotlight", isDirectory: true)
        return dir.appendingPathComponent("index.bin")
    }()

    /// Loads the saved index when it matches `config` (then replays changes since it was saved), else crawls.
    func start(config: CrawlConfig) {
        let gen = generation.withLock { $0 }
        queue.async { [self] in
            if let data = try? Data(contentsOf: Self.storeURL),
               let saved = try? FileIndex.deserialize(data), saved.configKey == config.key {
                live = LiveIndex(index: saved.index, config: config)
                lastEventID = saved.eventID
                publish(status: "Index loaded (\(Self.describe(saved.index.counts())))")
                startWatcher(config: config, since: saved.eventID)
            } else {
                rebuildOnQueue(config: config, gen: gen)
            }
        }
    }

    func rebuild(config: CrawlConfig) {
        let gen = generation.withLock { $0 += 1; return $0 }
        queue.async { [self] in rebuildOnQueue(config: config, gen: gen) }
    }

    private func rebuildOnQueue(config: CrawlConfig, gen: Int) {
        let isStale = { [generation] in generation.withLock { $0 } != gen }
        guard !isStale() else { return }
        watcher?.stop()
        watcher = nil
        let startID = FSEventsWatcher.currentEventID
        onUpdate(Update(index: nil, status: "Updating index…"))
        let t0 = Date()
        let onUpdate = onUpdate
        let index = Crawler.buildIndex(config: config, isCancelled: isStale) { n in
            onUpdate(Update(index: nil, status: "Updating index… (\(n.formatted()) entries)"))
        }
        guard !isStale() else { return }
        live = LiveIndex(index: index, config: config)
        lastEventID = startID
        let seconds = Date().timeIntervalSince(t0)
        publish(status: String(format: "Index updated (%.1f sec, %@)", seconds, Self.describe(index.counts())))
        saveNow()
        // Replays whatever changed while the crawl was running.
        startWatcher(config: config, since: startID)
    }

    private func startWatcher(config: CrawlConfig, since: UInt64) {
        let w = FSEventsWatcher(paths: config.roots, since: since) { [weak self] events in
            guard let self else { return }
            self.queue.async { self.handle(events, config: config) }
        }
        if !w.start() { onUpdate(Update(index: nil, status: "Live updates unavailable; use Rebuild Index")) }
        watcher = w
    }

    private func handle(_ events: [FSEventsWatcher.Event], config: CrawlConfig) {
        guard live?.config == config else { return }  // events from a replaced watcher
        if events.contains(where: \.requiresFullRescan) {
            rebuildOnQueue(config: config, gen: generation.withLock { $0 += 1; return $0 })
            return
        }
        lastEventID = max(lastEventID, events.map(\.id).max() ?? 0)
        let paths = events.filter { !$0.isHistoryDone }.map(\.path)
        guard !paths.isEmpty, live!.apply(changedPaths: paths) else { return }
        publish(status: "Index updated (\(Self.describe(live!.index.counts())))")
        if !saveScheduled {
            saveScheduled = true
            queue.asyncAfter(deadline: .now() + 30) { [self] in
                saveScheduled = false
                saveNow()
            }
        }
    }

    private func publish(status: String) {
        guard let live else { return }
        unsaved.withLock { $0 = Snapshot(index: live.index, eventID: lastEventID, key: live.config.key) }
        onUpdate(Update(index: live.index, status: status))
    }

    /// Writes the latest unsaved snapshot. Safe to call from any thread (used at quit).
    func saveNow() {
        saveLock.withLock {
            guard let snap = unsaved.withLock({ s -> Snapshot? in defer { s = nil }; return s }) else { return }
            do {
                try FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try snap.index.serialized(eventID: snap.eventID, configKey: snap.key).write(to: Self.storeURL, options: .atomic)
            } catch {
                NSLog("SuperSpotlight: saving index failed: \(error)")
            }
        }
    }

    static func describe(_ c: FileIndex.Counts) -> String {
        "\(c.files.formatted()) files, \(c.directories.formatted()) folders"
    }
}
