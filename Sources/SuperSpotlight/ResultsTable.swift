import AppKit
import SuperSpotlightCore
import SwiftUI
import UniformTypeIdentifiers

/// Icons and kind names, cached per extension (apps per path) so scrolling stays cheap.
@MainActor
enum FileInfo {
    private static var icons: [String: NSImage] = [:]
    private static var kinds: [String: String] = [:]

    static func icon(_ id: Int32, in index: FileIndex) -> NSImage {
        let ext = index.pathExtension(id)
        let isDir = index.isDirectory(id)
        let key = isDir && ext == "app" ? index.path(id) : (isDir ? "/dir" : ext)
        if let i = icons[key] { return i }
        let image: NSImage
        if isDir && ext == "app" {
            image = NSWorkspace.shared.icon(forFile: key)
        } else if isDir {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        image.size = NSSize(width: 16, height: 16)
        icons[key] = image
        return image
    }

    static func kind(_ id: Int32, in index: FileIndex) -> String {
        let ext = index.pathExtension(id)
        if index.isDirectory(id) { return ext == "app" ? "Application" : "Folder" }
        if let k = kinds[ext] { return k }
        let k = UTType(filenameExtension: ext)?.localizedDescription ?? "Document"
        kinds[ext] = k
        return k
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

final class ResultsTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

struct ResultsTable: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.style = .inset
        table.rowHeight = 20
        for (id, title, width) in [("name", "Name", 260.0), ("path", "Path", 360.0), ("size", "Size", 80.0),
                                   ("kind", "Kind", 120.0), ("modified", "Date Modified", 150.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(col)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.onKey = { [weak coordinator = context.coordinator] in coordinator?.handleKey($0) ?? false }
        table.setAccessibilityLabel("Search results")
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var table: ResultsTableView?
        private var version = -1
        private var index = FileIndex()
        private var rows: [Int32] = []

        init(model: AppModel) { self.model = model }

        func update() {
            guard let table, model.resultsVersion != version else { return }
            // Keep the selection by entry id across re-searches (ids are stable while the index lives).
            let selected = Set(table.selectedRowIndexes.map { rows[$0] })
            version = model.resultsVersion
            index = model.index
            rows = model.results
            table.reloadData()
            if !selected.isEmpty {
                let keep = IndexSet(rows.enumerated().filter { selected.contains($0.element) }.map(\.offset))
                table.selectRowIndexes(keep, byExtendingSelection: false)
            }
        }

        var selectedURLs: [URL] {
            guard let table else { return [] }
            var set = table.selectedRowIndexes
            if table.clickedRow >= 0, !set.contains(table.clickedRow) { set = [table.clickedRow] }
            return set.map { URL(fileURLWithPath: index.path(rows[$0])) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
            let id = rows[row]
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(col), owner: nil) as? NSTableCellView
                ?? makeCell(col)
            switch col {
            case "name":
                cell.textField?.stringValue = index.name(id)
                cell.imageView?.image = FileInfo.icon(id, in: index)
            case "path":
                let p = index.parent(id)
                cell.textField?.stringValue = p >= 0 ? index.path(p) : ""
            case "size":
                cell.textField?.stringValue = index.isDirectory(id) ? "--" : ByteCountFormatter.string(fromByteCount: index.size(id), countStyle: .file)
            case "kind":
                cell.textField?.stringValue = FileInfo.kind(id, in: index)
            default:
                cell.textField?.stringValue = FileInfo.dateFormatter.string(from: index.modified(id))
            }
            return cell
        }

        private func makeCell(_ col: String) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier(col)
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = col == "path" ? .byTruncatingMiddle : .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if col == "size" { text.alignment = .right }
            if col == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let key = d.key.flatMap(SearchEngine.SortKey.init) else { return }
            model.ascending = d.ascending
            model.sortKey = key
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            FileActions.open(selectedURLs)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            for item in FileActions.menu(for: selectedURLs).items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }

        func handleKey(_ event: NSEvent) -> Bool {
            let urls = selectedURLs
            guard !urls.isEmpty else { return false }
            let cmd = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 49: QuickLook.toggle(urls)  // space
            case 36, 76: cmd ? FileActions.reveal(urls) : FileActions.open(urls)  // return, enter
            case 51 where cmd: FileActions.trash(urls)  // cmd+delete
            default: return false
            }
            return true
        }
    }
}
