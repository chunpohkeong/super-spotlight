import AppKit
import Quartz
import SwiftUI

@main
struct SuperSpotlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Super Spotlight", id: "main") {
            MainView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Show Search Panel") { PanelController.shared.toggle() }
                Button("Rebuild Index") { AppModel.shared.rebuildIndex() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Super Spotlight", systemImage: "magnifyingglass") {
            Button("Show Search Panel (\(AppSettings.shared.hotKey.display))") { PanelController.shared.show() }
            Button("Open Main Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Rebuild Index") { AppModel.shared.rebuildIndex() }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit Super Spotlight") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppSettings.shared.applyActivationPolicy()
            HotKeyManager.shared.action = { PanelController.shared.toggle() }
            HotKeyManager.shared.register(AppSettings.shared.hotKey)
            AppModel.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.saveIndex() }
    }

    // Keep running from the menu bar after the main window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Quick Look panel controller: the delegate ends every responder chain, so previews work from any window.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = QuickLook.shared }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
}
