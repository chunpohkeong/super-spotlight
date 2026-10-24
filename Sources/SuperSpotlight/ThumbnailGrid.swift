import AppKit
import QuickLookThumbnailing
import SuperSpotlightCore
import SwiftUI

@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 2000 }

    func image(for path: String, size: CGFloat) async -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
        // Generation and decoding happen on Quick Look's own queues.
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache.setObject(rep.nsImage, forKey: path as NSString)
        return rep.nsImage
    }
}

struct ThumbnailGrid: View {
    @ObservedObject var model: AppModel
    @State private var selection: Set<Int32> = []
    @FocusState private var focused: Bool

    // shortcut: grid shows the first 5,000 results only; switch to an NSCollectionView if users need more.
    private static let limit = 5000

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(model.results.prefix(Self.limit), id: \.self) { id in
                    ThumbnailCell(path: model.index.path(id), name: model.index.name(id), selected: selection.contains(id))
                        .onTapGesture(count: 2) { FileActions.open([model.url(id)]) }
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) { selection.formSymmetricDifference([id]) } else { selection = [id] }
                            focused = true
                        }
                        .contextMenu { menuItems(for: selection.contains(id) ? selectedURLs : [model.url(id)]) }
                }
            }
            .padding(12)
            if model.results.count > Self.limit {
                Text("Showing first \(Self.limit.formatted()) of \(model.results.count.formatted()) results").foregroundStyle(.secondary).padding()
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { QuickLook.toggle(selectedURLs); return .handled }
        .onKeyPress(.return) { FileActions.open(selectedURLs); return .handled }
        .onChange(of: model.resultsVersion) { selection.formIntersection(model.results) }
        .accessibilityLabel("Search results thumbnails")
    }

    private var selectedURLs: [URL] { model.results.filter(selection.contains).map(model.url) }

    @ViewBuilder
    private func menuItems(for urls: [URL]) -> some View {
        Button("Open") { FileActions.open(urls) }
        Button("Open With…") { FileActions.openWith(urls) }
        Button("Reveal in Finder") { FileActions.reveal(urls) }
        Button("Quick Look") { QuickLook.toggle(urls) }
        Divider()
        Button("Copy Name") { FileActions.copyNames(urls) }
        Button("Copy Path") { FileActions.copyPaths(urls) }
        Button("Copy File") { FileActions.copyFiles(urls) }
        Divider()
        Button("Copy to…") { FileActions.copy(urls, move: false) }
        Button("Move to…") { FileActions.copy(urls, move: true) }
        Divider()
        Button("Move to Trash") { FileActions.trash(urls) }
    }
}

private struct ThumbnailCell: View {
    let path: String
    let name: String
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            Text(name).font(.caption).lineLimit(2).multilineTextAlignment(.center).frame(width: 112)
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .task(id: path) { image = await Thumbnails.shared.image(for: path, size: 96) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
