# Super Spotlight

Instant filename search for macOS. It keeps its own index of every file name, updates it live with FSEvents, and searches in milliseconds.

## Requirements

- macOS 14 or later, Apple Silicon or Intel
- Swift 6 toolchain (Xcode or the Command Line Tools)

## Build and run

```bash
./scripts/build-app.sh
open "build/Super Spotlight.app"
```

The script builds a universal release binary, wraps it in `build/Super Spotlight.app` and ad-hoc signs it.

With only the Command Line Tools installed, the script builds against the macOS 26 SDK. The macOS 27 SDK needs SwiftUI's macro plugin, which only Xcode ships. When you run `swift` yourself, set the SDK the same way:

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

## Full Disk Access

The app is not sandboxed. Without Full Disk Access, macOS asks once per protected folder (Desktop, Documents, Downloads and others), and some folders (Mail, Messages, Safari) stay hidden. To index everything:

System Settings > Privacy & Security > Full Disk Access > add **Super Spotlight**.

When access is missing, the main window shows a banner with a button that opens that pane.

## Using it

- **Global shortcut:** ⌥Space opens the floating search panel. You can change it in Settings.
  - Panel keys: ↑/↓ select, ↩ open, ⌘↩ reveal in Finder, ⌘Y Quick Look, esc close.
- **Main window:** a sortable results table, or thumbnails.
  - Table keys: Space Quick Look, ↩ open, ⌘↩ reveal, ⌘⌫ move to Trash.
  - Right-click for Open With, Copy Name/Path/File, Copy to, Move to.
- **Query syntax:** spaces mean AND, `|` means OR (`report pdf|invoice`).
  - Match modes: contains, prefix, suffix, exact, regex. "Aa" makes the search case-sensitive.
- **Filters:** files or folders only, extensions (chips or a custom list), size range, date modified.
- **Settings:**
  - Scope: home folder or all disks.
  - Excluded folders: absolute `/paths`, or bare names such as `node_modules` that match anywhere.
  - Hidden files, launch at login, hide Dock icon.
- **Index storage:** `~/Library/Application Support/SuperSpotlight/index.bin`.
  - The index loads instantly at launch, then FSEvents replays whatever changed since the last save.
  - **Rebuild Index** (⇧⌘R) crawls from scratch.

## Development

```bash
swift run sscheck                     # self-checks: search modes, filters, persistence, crawler, live updates
swift run -c release ssbench [root]   # crawl speed and query latency
```

On a macOS 27 Command Line Tools install, swift-testing's macros fail to load. That's why the checks are a plain executable.

| Target | Contents |
| --- | --- |
| `SuperSpotlightCore` | `FileIndex` (column store + persistence), `Crawler` (getattrlistbulk), `LiveIndex` (incremental updates), `FSEventsWatcher`, `SearchEngine` |
| `SuperSpotlight` | SwiftUI/AppKit app: main window, results table, thumbnail grid, floating panel, hotkey, settings, menu bar extra |
