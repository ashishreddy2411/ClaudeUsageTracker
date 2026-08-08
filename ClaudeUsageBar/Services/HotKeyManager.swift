import AppKit
import Carbon

extension Notification.Name {
    static let toggleUsagePopover = Notification.Name("com.claudeusagebar.togglePopover")
}

/// Global ⌘U hotkey via Carbon `RegisterEventHotKey`.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x43554252), id: 1) // 'CUBR'

    func register(keyCode: UInt32 = 32, modifiers: UInt32 = UInt32(cmdKey)) {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotKey()
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )

        guard status == noErr else { return }

        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if registerStatus == noErr {
            hotKeyRef = ref
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handleHotKey() {
        DispatchQueue.main.async {
            PopoverToggle.shared.toggle()
        }
    }
}

/// Best-effort toggle for SwiftUI `MenuBarExtra` window presentation.
@MainActor
final class PopoverToggle {
    static let shared = PopoverToggle()

    func toggle() {
        MenuBarPresentation.configureMenuBarWindows()

        // MenuBarExtra .window style hosts an NSPanel / NSWindow we can show/hide.
        let candidates = NSApp.windows.filter { MenuBarPresentation.isMenuBarHosted($0) }

        if let panel = candidates.first(where: { $0.isVisible }) {
            panel.orderOut(nil)
            // Sync after orderOut so we don't leave presentation options stuck.
            DispatchQueue.main.async {
                MenuBarPresentation.syncHoldToVisibleHostWindows()
            }
            return
        }

        // Keep menu bar visible *before* any activation (presentationOptions apply when active).
        MenuBarPresentation.beginMenuBarUI()

        if let panel = candidates.first {
            MenuBarPresentation.configure(panel)
            // Prefer orderFrontRegardless so we join the fullscreen Space without relying
            // solely on activation; then activate for keyboard focus inside the panel.
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            MenuBarPresentation.beginMenuBarUI()
            return
        }

        // Fallback: activate so a subsequent MenuBarExtra click path can run, then re-assert.
        NSApp.activate(ignoringOtherApps: true)
        MenuBarPresentation.beginMenuBarUI()
        clickStatusItemIfPossible()
    }

    private func clickStatusItemIfPossible() {
        guard let statusBarWindow = NSApp.windows.first(where: {
            String(describing: type(of: $0)).contains("StatusBar")
                || $0.className.contains("NSStatusBar")
        }) else {
            return
        }
        statusBarWindow.orderFrontRegardless()
    }
}
