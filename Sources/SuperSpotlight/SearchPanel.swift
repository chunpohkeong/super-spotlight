import AppKit
import Quartz
import SuperSpotlightCore
import SwiftUI

/// Spotlight-style floating panel. Non-activating, so the frontmost app keeps focus until a result is opened.
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    override func resignKey() {
        super.resignKey()
        // Quick Look takes key status while previewing; keep the panel up underneath it.
        if !(QLPreviewPanelVisible()) { orderOut(nil) }
    }
}

@MainActor private func QLPreviewPanelVisible() -> Bool {
    QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
}

@MainActor
final class PanelController {
    static let shared = PanelController()
    private lazy var panel: SearchPanel = {
        let p = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.contentView = NSHostingView(rootView: PanelView(model: AppModel.shared))
        return p
    }()

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        if let screen = NSScreen.main?.visibleFrame {
            let f = panel.frame
            panel.setFrameOrigin(NSPoint(x: screen.midX - f.width / 2, y: screen.minY + screen.height * 0.62 - f.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .panelShown, object: nil)
    }

    func hide() { panel.orderOut(nil) }
}

extension Notification.Name {
    static let panelShown = Notification.Name("SuperSpotlight.panelShown")
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var selected = 0
    @FocusState private var focused: Bool
    private static let limit = 200

    private var rows: ArraySlice<Int32> { model.results.prefix(Self.limit) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search files", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24))
                    .focused($focused)
                    .accessibilityLabel("Search file names")
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.return, phases: .down) { press in
                        guard let url = selectedURL else { return .ignored }
                        if press.modifiers.contains(.command) { FileActions.reveal([url]) } else { FileActions.open([url]) }
                        PanelController.shared.hide()
                        return .handled
                    }
                    .onKeyPress(.escape) { PanelController.shared.hide(); return .handled }
                    .onKeyPress(characters: ["y"], phases: .down) { press in
                        guard press.modifiers.contains(.command), let url = selectedURL else { return .ignored }
                        QuickLook.toggle([url])
                        return .handled
                    }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                List(Array(rows.enumerated()), id: \.element) { offset, id in
                    PanelRow(index: model.index, id: id)
                        .listRowBackground(offset == selected ? Color.accentColor.opacity(0.3) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            FileActions.open([model.url(id)])
                            PanelController.shared.hide()
                        }
                        .onTapGesture { selected = offset }
                        .accessibilityAddTraits(offset == selected ? .isSelected : [])
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: selected) { _, new in
                    if new < rows.count { proxy.scrollTo(rows[rows.startIndex + new]) }
                }
            }
            HStack {
                Text(model.searchError ?? model.searchStatus)
                if model.location != nil { Text("in \(model.locationTitle)") }
                Spacer()
                Text("↩ open  ⌘↩ reveal  ⌘Y preview  esc close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(.regularMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .panelShown)) { _ in focused = true }
        .onChange(of: model.resultsVersion) { selected = 0 }
    }

    private var selectedURL: URL? { selected < rows.count ? model.url(rows[rows.startIndex + selected]) : nil }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        selected = min(max(0, selected + delta), rows.count - 1)
        return .handled
    }
}

private struct PanelRow: View {
    let index: FileIndex
    let id: Int32

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileInfo.icon(id, in: index)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(index.name(id)).lineLimit(1)
                Text(index.parent(id) >= 0 ? index.path(index.parent(id)) : "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
