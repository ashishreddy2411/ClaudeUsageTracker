import AppKit
import SwiftUI

/// Airy grouped Settings — Apple Form utility + Anthropic short footers.
/// Form uses system grouped chrome and label hierarchy so Light / Dark / Auto stay
/// readable (no forced ink on dark section cards).
struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("Alerts", isOn: alertsBinding)

                if preferences.notificationsEnabled {
                    LabeledContent("Alert at") {
                        Menu {
                            ForEach(PreferencesStore.allThresholds, id: \.self) { threshold in
                                Toggle(
                                    "\(threshold)%",
                                    isOn: thresholdBinding(threshold)
                                )
                            }
                        } label: {
                            Text(alertThresholdSummary)
                        }
                    }
                } else if preferences.notificationsAuthorizationDenied {
                    // Soft hint after denial — macOS will not re-prompt.
                    Button {
                        NotificationService.shared.openSystemNotificationSettings()
                    } label: {
                        Text("Enable notifications in System Settings")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                if preferences.notificationsEnabled {
                    Text("One alert per threshold per usage window.")
                } else if preferences.notificationsAuthorizationDenied {
                    Text("Notifications were blocked for this app.")
                }
            }

            Section {
                Picker("Refresh every", selection: $preferences.refreshIntervalMinutes) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                }
                .pickerStyle(.menu)
                .onChange(of: preferences.refreshIntervalMinutes) { _ in
                    monitor.rescheduleTimer()
                }

                Toggle("Show % in menu bar", isOn: $preferences.showPercentInMenu)

                // Only meaningful once a number is on screen; the ring still follows
                // this selection, but the choice is easiest to understand next to the
                // toggle that reveals the number.
                if preferences.showPercentInMenu {
                    Picker("Show", selection: $preferences.menuPercentSource) {
                        ForEach(MenuPercentSource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
            } header: {
                Text("General")
            } footer: {
                if let launchAtLoginError = preferences.launchAtLoginError {
                    Text(launchAtLoginError)
                } else {
                    Text("Toggle popover with ⌘U.")
                }
            }

            Section {
                if monitor.canDisconnect {
                    if monitor.authStatus.needsOfficialSetupGuidance {
                        Link("Open official Claude Code setup", destination: ClaudeCodeSetup.documentationURL)
                    }
                    if monitor.authStatus != .ready() {
                        Button("Retry Keychain Access") {
                            monitor.refreshNow()
                        }
                    }

                    Button("Disconnect from ClaudeUsageBar", role: .destructive) {
                        monitor.disconnect()
                        dismiss()
                    }
                } else {
                    Button {
                        dismiss()
                        monitor.connect()
                    } label: {
                        Text("Connect Claude Code")
                            .foregroundStyle(PopoverTheme.coral)
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                Text(
                    monitor.canDisconnect
                        ? "Disconnecting stops credential reads and clears ClaudeUsageBar’s local usage state. Claude Code stays signed in."
                        : "Reads your existing Claude Code sign-in from macOS Keychain only after you connect."
                )
            }

            Section {
                Button("Quit ClaudeUsageBar", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.automatic)
        .background(PopoverTheme.settingsFloor.ignoresSafeArea())
        .frame(width: 328)
        .frame(minHeight: 360)
        .navigationTitle("Settings")
        .tint(PopoverTheme.coral)
        .onAppear {
            // Truth = system permission: stale ON without grant flips OFF.
            NotificationService.shared.reconcileWithSystemPermission(preferences: preferences)
            preferences.reconcileLaunchAtLogin()
        }
    }

    // MARK: - Alerts helpers

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { preferences.launchAtLogin },
            set: { preferences.setLaunchAtLogin($0) }
        )
    }

    /// NotificationService owns intent generation so stale permission callbacks cannot
    /// overwrite a later toggle.
    private var alertsBinding: Binding<Bool> {
        Binding(
            get: { preferences.notificationsEnabled },
            set: { wantsOn in
                NotificationService.shared.setAlertsEnabled(
                    wantsOn,
                    preferences: preferences
                )
            }
        )
    }

    private var alertThresholdSummary: String {
        let selected = PreferencesStore.allThresholds.filter {
            preferences.enabledThresholds.contains($0)
        }
        if selected.isEmpty { return "None" }
        return selected.map { "\($0)%" }.joined(separator: ", ")
    }

    private func thresholdBinding(_ threshold: Int) -> Binding<Bool> {
        Binding(
            get: { preferences.enabledThresholds.contains(threshold) },
            set: { enabled in
                var next = preferences.enabledThresholds
                if enabled {
                    next.insert(threshold)
                } else {
                    next.remove(threshold)
                }
                preferences.enabledThresholds = next
            }
        )
    }
}
