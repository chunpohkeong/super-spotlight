import SuperSpotlightCore
import SwiftUI

struct MainView: View {
    @ObservedObject var model = AppModel.shared
    @ObservedObject var settings = AppSettings.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess { FullDiskAccessBanner() }
            searchBar.padding([.horizontal, .top], 12).padding(.bottom, 6)
            filterBar.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if model.results.isEmpty {
                ContentUnavailableView(model.query.hasCriteria ? "No Results" : "Type to Search",
                                       systemImage: "magnifyingglass",
                                       description: Text(model.query.hasCriteria ? "Try another name or loosen the filters."
                                                         : "Spaces mean AND, | means OR."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.thumbnails {
                ThumbnailGrid(model: model)
            } else {
                ResultsTable(model: model)
            }
            Divider()
            HStack {
                if let err = model.searchError {
                    Text(err).foregroundStyle(.red)
                } else {
                    Text(model.searchStatus)
                }
                Spacer()
                Text(model.indexStatus).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("File name", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel("Search file names")
            LocationMenu(model: model)
            Picker("Match", selection: $model.mode) {
                Text("Contains").tag(SearchQuery.Mode.contains)
                Text("Prefix").tag(SearchQuery.Mode.prefix)
                Text("Suffix").tag(SearchQuery.Mode.suffix)
                Text("Exact").tag(SearchQuery.Mode.exact)
                Text("Regex").tag(SearchQuery.Mode.regex)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Match mode")
            Toggle("Aa", isOn: $model.caseSensitive)
                .toggleStyle(.button)
                .help("Case sensitive")
                .accessibilityLabel("Case sensitive")
            Picker("Kind", selection: $model.kind) {
                Text("Files + Folders").tag(SearchQuery.Kind.all)
                Text("Files").tag(SearchQuery.Kind.files)
                Text("Folders").tag(SearchQuery.Kind.folders)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Kind")
            Picker("View", selection: $model.thumbnails) {
                Image(systemName: "list.bullet").tag(false).accessibilityLabel("List")
                Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel("Thumbnails")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("View mode")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Text("Extension").foregroundStyle(.secondary)
            Toggle("any", isOn: Binding(get: { model.chips.isEmpty && model.customExtensions.isEmpty },
                                        set: { if $0 { model.chips = []; model.customExtensions = "" } }))
                .toggleStyle(.button)
            ForEach(AppModel.extensionChips, id: \.self) { ext in
                Toggle(ext, isOn: Binding(get: { model.chips.contains(ext) },
                                          set: { if $0 { model.chips.insert(ext) } else { model.chips.remove(ext) } }))
                    .toggleStyle(.button)
            }
            TextField("Custom, e.g. swift,cpp", text: $model.customExtensions)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .accessibilityLabel("Custom extensions")
            Divider().frame(height: 18)
            Text("Size").foregroundStyle(.secondary)
            TextField("min", text: $model.minSizeText).textFieldStyle(.roundedBorder).frame(width: 52)
                .accessibilityLabel("Minimum size")
            Text("–")
            TextField("max", text: $model.maxSizeText).textFieldStyle(.roundedBorder).frame(width: 52)
                .accessibilityLabel("Maximum size")
            Picker("Unit", selection: $model.sizeUnit) {
                ForEach(AppModel.SizeUnit.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            Picker("Modified", selection: $model.timeFilter) {
                ForEach(AppModel.TimeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel("Date modified")
            Spacer(minLength: 0)
            Toggle("Hidden", isOn: $settings.showHidden).toggleStyle(.checkbox)
        }
        .controlSize(.small)
    }
}

struct LocationMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Button("Everywhere") { model.location = nil }
            Divider()
            ForEach(AppModel.quickLocations, id: \.path) { loc in
                Button(loc.title) { model.location = loc.path }
            }
            Divider()
            Button("Choose Folder…") { model.chooseLocation() }
        } label: {
            Label(model.locationTitle, systemImage: model.location == nil ? "globe" : "folder")
        }
        .fixedSize()
        .help(model.location ?? "Search the whole index")
        .accessibilityLabel("Search location: \(model.locationTitle)")
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "lock.shield").accessibilityHidden(true)
            Text("Grant Full Disk Access so Super Spotlight can index protected folders (Mail, Messages, Safari, other users).")
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
        .font(.callout)
        .padding(10)
        .background(.yellow.opacity(0.2))
    }
}
