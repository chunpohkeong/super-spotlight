import AppKit
import ServiceManagement
import SuperSpotlightCore
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Scope: String, CaseIterable, Identifiable {
        case home, allDisks
        var id: String { rawValue }
        var title: String { self == .home ? "Home folder" : "All disks" }
    }

    static let defaultExcluded = ["/System", "/Volumes", "/dev", "/private/var", "/Library/Caches", "~/Library/Caches", "~/Library/CloudStorage", ".Trash"]

    private let defaults = UserDefaults.standard

    @Published var scope: Scope { didSet { defaults.set(scope.rawValue, forKey: "scope") } }
    @Published var excluded: [String] { didSet { defaults.set(excluded, forKey: "excluded") } }
    @Published var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    @Published var hideDockIcon: Bool {
        didSet {
            defaults.set(hideDockIcon, forKey: "hideDockIcon")
            applyActivationPolicy()
        }
    }
    @Published var hotKey: HotKeyCombo {
        didSet {
            defaults.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey")
            HotKeyManager.shared.register(hotKey)
        }
    }

    private init() {
        scope = Scope(rawValue: defaults.string(forKey: "scope") ?? "") ?? .home
        excluded = defaults.stringArray(forKey: "excluded") ?? Self.defaultExcluded
        showHidden = defaults.bool(forKey: "showHidden")
        hideDockIcon = defaults.bool(forKey: "hideDockIcon")
        hotKey = defaults.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) } ?? .default
    }

    var crawlConfig: CrawlConfig {
        switch scope {
        case .home:
            return CrawlConfig(roots: [NSHomeDirectory()], excluded: excluded)
        case .allDisks:
            let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
                .map(\.path).filter { $0.hasPrefix("/Volumes/") }
            return CrawlConfig(roots: ["/"] + volumes, excluded: excluded)
        }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var newExclusion = ""
    @State private var selectedExclusion: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Index") {
                Picker("Search scope", selection: $settings.scope) {
                    ForEach(AppSettings.Scope.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Excluded folders") {
                    VStack(alignment: .leading, spacing: 6) {
                        List(settings.excluded, id: \.self, selection: $selectedExclusion) { Text($0) }
                            .frame(minHeight: 140)
                            .accessibilityLabel("Excluded folders")
                        HStack {
                            TextField("Folder name or /path", text: $newExclusion)
                                .onSubmit(addTypedExclusion)
                            Button("Add", action: addTypedExclusion).disabled(newExclusion.isEmpty)
                            Button("Choose…", action: chooseExclusion)
                            Button("Remove") {
                                settings.excluded.removeAll { $0 == selectedExclusion }
                                selectedExclusion = nil
                            }
                            .disabled(selectedExclusion == nil)
                        }
                        Text("Names without a leading / match folders anywhere (e.g. node_modules). Cloud drives (~/Library/CloudStorage) are excluded by default because listing them goes over the network.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Show hidden files", isOn: $settings.showHidden)
                Button("Rebuild Index") { AppModel.shared.rebuildIndex() }
            }
            Section("General") {
                LabeledContent("Show/Hide search panel") { HotKeyRecorder(combo: $settings.hotKey) }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Hide Dock icon", isOn: $settings.hideDockIcon)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }

    private func addTypedExclusion() {
        let s = newExclusion.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !settings.excluded.contains(s) else { return }
        settings.excluded.append(s)
        newExclusion = ""
    }

    private func chooseExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.excluded.contains(url.path) { settings.excluded.append(url.path) }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
