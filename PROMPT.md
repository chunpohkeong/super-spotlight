Build an original native macOS app named "Super Spotlight" in this folder: an instant filename search tool (Everything-style) for macOS. Use Swift 6 + SwiftUI with AppKit where needed, Xcode project generated via XcodeGen (project.yml) or a Swift Package with an app target. Target macOS 14+, Apple Silicon + Intel. No third-party dependencies unless unavoidable. Not sandboxed for v1 (direct distribution); ask user to grant Full Disk Access, and show a banner with a button opening System Settings > Privacy > Full Disk Access when access is missing.

CORE: INDEX
- Build an in-memory filename index of the chosen scope: "Home" (~) or "All disks" (/ plus mounted volumes).
- Crawl fast with getattrlistbulk or FileManager.enumerator with prefetched keys (name, isDirectory, fileSize, contentModificationDate). Store compact records: name, parent index, size, mtime, isDir. Paths rebuilt from parent chain.
- Persist index to Application Support (binary, zlib/lzfse compressed) so launch is instant; load then refresh in background.
- Keep index live with FSEvents (FSEventStreamCreate, kFSEventStreamCreateFlagFileEvents) and apply incremental adds/removes/renames. Watch volume mount/unmount (NSWorkspace notifications).
- Excluded directories list (default: /System, /private/var, /Library/Caches, ~/Library/Caches, .Trash, node_modules optional). Editable in Settings.
- Menu "Rebuild Index". Status line: "Updating index…" / "Index updated (X.X s, N files, M folders)".

CORE: SEARCH
- Search-as-you-type, results under ~50 ms for 2M entries. Run on a background actor, cancel stale queries.
- Match modes: contains, prefix, suffix, exact, multi-keyword (space = AND, "|" = OR), regex (NSRegularExpression). Case-insensitive toggle.
- Filters: file+folder / only files / only folders; extension chips (any, txt, pdf, docx, xlsx, pptx) plus custom comma list; size min/max (MB/GB); modified within (hours/days/all time).
- Status: "N files found (time X.XXX sec)".

UI
- Main window: search field top, filter bar, results.
- Results as sortable NSTableView-backed table (name with icon, path, size, kind, date modified); handle 100k+ rows virtualized.
- Toggle list / thumbnail grid (QLThumbnailGenerator, NSCache, decode off main thread).
- Spacebar = Quick Look (QLPreviewPanel). Enter = open. Cmd+Enter = reveal in Finder.
- Context menu: Open, Open With…, Reveal in Finder, Copy Name, Copy Path, Copy File, Copy to…, Move to…, Move to Trash (confirm, use NSWorkspace.recycle). Multi-select supported.
- Global hotkey (default Option+Space, configurable in Settings) shows/hides a floating Spotlight-style panel (NSPanel, nonactivating, centered) with the same search; Esc hides.
- Menu bar extra icon with Show, Rebuild Index, Settings, Quit. Option to hide Dock icon.
- Settings window: scope, excluded dirs (add/remove), hotkey recorder, launch at login (SMAppService), show hidden files toggle.
- Light/dark mode, keyboard-first navigation, VoiceOver labels.

QUALITY
- Separate modules: Indexer, FSEventsWatcher, SearchEngine, UI.
- Unit tests for SearchEngine match modes and filters, and index serialization round-trip.
- Benchmark script that indexes ~ and prints entries/sec and query latency.
- README with build/run steps and Full Disk Access note.

Out of scope: accounts, payments, telemetry, network calls, content (full-text) search.

Work in steps: scaffold project and build, then indexer + tests, then search engine + tests, then UI, then hotkey panel and settings. Build and run after each step and fix errors before moving on.
