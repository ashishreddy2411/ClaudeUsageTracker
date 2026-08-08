import AppKit
import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var monitor = UsageMonitor.shared
    @ObservedObject private var preferences = PreferencesStore.shared

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(monitor: monitor, preferences: preferences)
        } label: {
            UsageMenuLabel(monitor: monitor, preferences: preferences)
        }
        .menuBarExtraStyle(.window)
    }
}
