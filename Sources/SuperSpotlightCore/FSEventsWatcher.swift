import CoreServices
import Foundation

/// Thin wrapper over an FSEvents stream with per-file events delivered on a private queue.
public final class FSEventsWatcher: @unchecked Sendable {
    public struct Event: Sendable {
        public var path: String
        public var flags: UInt32
        public var id: UInt64

        /// The stream lost track of changes below `path`; the caller must rescan it fully.
        public var requiresFullRescan: Bool {
            flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged) != 0
        }
        public var isHistoryDone: Bool { flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }
    }

    private let paths: [String]
    private let since: UInt64?
    private let handler: @Sendable ([Event]) -> Void
    private let queue = DispatchQueue(label: "SuperSpotlight.fsevents")
    private var stream: FSEventStreamRef?

    public init(paths: [String], since: UInt64?, handler: @escaping @Sendable ([Event]) -> Void) {
        self.paths = paths
        self.since = since
        self.handler = handler
    }

    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    @discardableResult
    public func start() -> Bool {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let p = list[i] as? String else { continue }
                events.append(Event(path: p, flags: flags[i], id: ids[i]))
            }
            watcher.handler(events)
        }
        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                          since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, createFlags)
        else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
