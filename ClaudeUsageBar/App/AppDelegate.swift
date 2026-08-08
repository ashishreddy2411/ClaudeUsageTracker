import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: hide from Dock (also set LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)

        // Never hide the system menu bar while this accessory is active
        // (NSApplication.presentationOptions). Install observers before any UI opens.
        MenuBarPresentation.install()
        MenuBarPresentation.assertMenuBarVisible()

        let prefs = PreferencesStore.shared
        HotKeyManager.shared.register(
            keyCode: prefs.hotkeyKeyCode,
            modifiers: prefs.hotkeyModifiers
        )

        // Don't leave stale Alerts ON without system permission (migration + denial).
        NotificationService.shared.reconcileWithSystemPermission(preferences: prefs)

        UsageMonitor.shared.start()

        // MenuBarExtra windows are created asynchronously — configure for fullscreen Spaces.
        DispatchQueue.main.async {
            MenuBarPresentation.configureMenuBarWindows()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Belt-and-suspenders with MenuBarPresentation observers (FB13544993).
        if NSApp.windows.contains(where: { MenuBarPresentation.isMenuBarHosted($0) && $0.isVisible }) {
            MenuBarPresentation.beginMenuBarUI()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarPresentation.endMenuBarUI()
        UsageMonitor.shared.stop()
        HotKeyManager.shared.unregister()
    }
}
