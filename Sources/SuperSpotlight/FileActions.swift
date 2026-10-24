import AppKit
import Quartz
import UniformTypeIdentifiers

@MainActor
enum FileActions {
    static func open(_ urls: [URL]) {
        for url in urls { NSWorkspace.shared.open(url) }
    }

    static func openWith(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = "Choose an application"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    static func copyNames(_ urls: [URL]) { copyString(urls.map(\.lastPathComponent).joined(separator: "\n")) }
    static func copyPaths(_ urls: [URL]) { copyString(urls.map(\.path).joined(separator: "\n")) }

    static func copyFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    private static func copyString(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func copy(_ urls: [URL], move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move Here" : "Copy Here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var failures: [String] = []
        for url in urls {
            let target = dest.appendingPathComponent(url.lastPathComponent)
            do {
                // Never overwrite: an existing target is reported instead.
                if move { try FileManager.default.moveItem(at: url, to: target) } else { try FileManager.default.copyItem(at: url, to: target) }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { alert(move ? "Some items could not be moved" : "Some items could not be copied", failures.joined(separator: "\n")) }
    }

    static func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let a = NSAlert()
        a.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash?" : "Move \(urls.count) items to the Trash?"
        a.informativeText = "They will be moved to the Trash."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error { Task { @MainActor in alert("Could not move to Trash", error.localizedDescription) } }
        }
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    static func menu(for urls: [URL]) -> NSMenu {
        let m = NSMenu()
        guard !urls.isEmpty else { return m }
        m.addItem(ActionItem("Open") { open(urls) })
        m.addItem(ActionItem("Open With…") { openWith(urls) })
        m.addItem(ActionItem("Reveal in Finder") { reveal(urls) })
        m.addItem(ActionItem("Quick Look") { QuickLook.toggle(urls) })
        m.addItem(.separator())
        m.addItem(ActionItem("Copy Name") { copyNames(urls) })
        m.addItem(ActionItem("Copy Path") { copyPaths(urls) })
        m.addItem(ActionItem("Copy File") { copyFiles(urls) })
        m.addItem(.separator())
        m.addItem(ActionItem("Copy to…") { copy(urls, move: false) })
        m.addItem(ActionItem("Move to…") { copy(urls, move: true) })
        m.addItem(.separator())
        m.addItem(ActionItem("Move to Trash") { trash(urls) })
        return m
    }
}

final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Quick Look panel driven from the app delegate (the end of every responder chain).
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private(set) var urls: [URL] = []

    static func toggle(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if !urls.isEmpty {
            shared.urls = urls
            panel.updateController()
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
