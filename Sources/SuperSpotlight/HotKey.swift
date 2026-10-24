import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: UInt32
    var display: String

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), display: "⌥Space")

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// nil for keys without a command/option/control modifier, which would swallow normal typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let key: String
        switch Int(event.keyCode) {
        case kVK_Space: key = "Space"
        case kVK_Return: key = "↩"
        case kVK_Tab: key = "⇥"
        default: key = event.charactersIgnoringModifiers?.uppercased() ?? "#\(event.keyCode)"
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key)
    }
}

/// Global hot key through Carbon's RegisterEventHotKey (works without Accessibility permission).
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ combo: HotKeyCombo) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { HotKeyManager.shared.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x5353_5054), id: 1)  // "SSPT"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("SuperSpotlight: hot key \(combo.display) unavailable (\(status))") }
    }
}

struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type shortcut… (Esc cancels)" : combo.display) {
            recording ? stop() : start()
        }
        .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(combo.display). Click to change")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
            } else if let c = HotKeyCombo(event: event) {
                combo = c
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
