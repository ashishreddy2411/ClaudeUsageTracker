import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var preferences: PreferencesStore

    init(monitor: UsageMonitor, preferences: PreferencesStore) {
        self.monitor = monitor
        self.preferences = preferences
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, shouldShowSetup ? 4 : 20)

                Group {
                    if shouldShowSetup {
                        SetupHelpView(
                            authStatus: effectiveSetupStatus,
                            isRefreshing: monitor.isRefreshing,
                            onConnect: { monitor.connect() },
                            onRetry: { monitor.refreshNow() }
                        )
                        .padding(.horizontal, 24)
                    } else if monitor.usage == nil {
                        UsageEmptyStateView(
                            title: monitor.error.emptyStateTitle ?? "Loading usage…",
                            message: monitor.error.emptyStateMessage
                                ?? "Fetching your session and weekly usage from Anthropic.",
                            isRefreshing: monitor.isRefreshing,
                            onRetry: { monitor.refreshNow() }
                        )
                        .padding(.horizontal, 24)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            if let banner = monitor.error.bannerMessage, !monitor.error.isAuthRelated {
                                bannerView(banner)
                            } else if monitor.error.isAuthRelated, monitor.usage != nil {
                                authBanner
                            }
                            usageSection
                        }
                        .padding(.horizontal, 24)
                    }
                }

                Spacer(minLength: 20)

                footerBand
            }
            .frame(width: 328)
            .frame(minHeight: shouldShowSetup ? 300 : 268)
            .background(surfaceBackground.ignoresSafeArea())
            .navigationDestination(for: PopoverDestination.self) { destination in
                switch destination {
                case .settings:
                    SettingsView(monitor: monitor, preferences: preferences)
                }
            }
        }
        .onAppear {
            // Click-open path: observers also cover this; keep explicit for reliability.
            MenuBarPresentation.beginMenuBarUI()
            monitor.refreshIfStaleOnPopoverOpen()
        }
        .onDisappear {
            // Defer so NavigationStack pushes do not end the hold while the panel stays open.
            DispatchQueue.main.async {
                MenuBarPresentation.syncHoldToVisibleHostWindows()
            }
        }
    }

    /// Adaptive panel floor — same semantic background for signed-out and signed-in.
    private var surfaceBackground: Color {
        PopoverTheme.canvas
    }

    private var effectiveSetupStatus: AuthStatus {
        if case .unknown = monitor.authStatus {
            return .disconnected
        }
        return monitor.authStatus
    }

    private var shouldShowSetup: Bool {
        if monitor.usage != nil { return false }
        switch monitor.authStatus {
        case .ready:
            return false
        default:
            return true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Claude Usage")
                .font(PopoverTheme.brandTitle())
                .foregroundStyle(PopoverTheme.ink)
                .tracking(-0.3)
            Spacer(minLength: 8)
            if monitor.isRefreshing, !shouldShowSetup {
                ProgressView()
                    .controlSize(.small)
                    .tint(PopoverTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude Usage")
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            UsageBarRow(
                title: "Session",
                window: monitor.usage?.fiveHour,
                stale: monitor.isStale
            )
            Rectangle()
                .fill(PopoverTheme.hairline)
                .frame(height: 1)
            UsageBarRow(
                title: "Weekly",
                window: monitor.usage?.sevenDay,
                stale: monitor.isStale
            )
        }
    }

    private var authBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(monitor.error.bannerMessage ?? effectiveSetupStatus.setupMessage)
                .font(PopoverTheme.caption())
                .foregroundStyle(PopoverTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if effectiveSetupStatus.needsOfficialSetupGuidance {
                Link("Open official Claude Code setup", destination: ClaudeCodeSetup.documentationURL)
                    .buttonStyle(CoralPillButtonStyle())
                Button("Retry") {
                    monitor.refreshNow()
                }
                .buttonStyle(QuietTextButtonStyle())
                .disabled(monitor.isRefreshing)
            } else {
                Button(effectiveSetupStatus.showsConnectionButton ? "Connect Claude Code" : "Retry") {
                    if effectiveSetupStatus.showsConnectionButton {
                        monitor.connect()
                    } else {
                        monitor.refreshNow()
                    }
                }
                .buttonStyle(CoralPillButtonStyle(disabled: monitor.isRefreshing))
                .disabled(monitor.isRefreshing)
            }
        }
    }

    /// Apple thin utility footer; disconnect lives in Settings only.
    private var footerBand: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(PopoverTheme.hairline)
                .frame(height: 1)

            HStack(spacing: 0) {
                if !shouldShowSetup {
                    // Label doubles as the throttle explanation so a blocked click is
                    // never mistaken for a broken button.
                    Button(monitor.refreshButtonTitle) {
                        monitor.refreshNow()
                    }
                    .buttonStyle(QuietTextButtonStyle())
                    .disabled(monitor.isRefreshing || monitor.manualRefreshBlockedFor != nil)
                    .keyboardShortcut("r", modifiers: .command)

                    Text("·")
                        .font(PopoverTheme.footerLink())
                        .foregroundStyle(PopoverTheme.mutedSoft)
                        .padding(.horizontal, 8)
                }

                NavigationLink(value: PopoverDestination.settings) {
                    Text("Settings")
                }
                .buttonStyle(QuietTextButtonStyle())
                .help("Open Settings")
                .accessibilityLabel("Settings")

                Spacer(minLength: 8)

                if !shouldShowSetup, let lastUpdated = monitor.lastUpdated {
                    Text(relativeUpdated(lastUpdated))
                        .font(PopoverTheme.finePrint())
                        .foregroundStyle(PopoverTheme.mutedSoft)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(PopoverTheme.canvas)
        }
    }

    private func relativeUpdated(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return monitor.isStale ? "\(relative) · stale" : relative
    }

    private func bannerView(_ message: String) -> some View {
        Text(message)
            .font(PopoverTheme.caption())
            .foregroundStyle(PopoverTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private enum PopoverDestination: Hashable {
    case settings
}

struct UsageBarRow: View {
    let title: String
    let window: UsageWindow?
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(PopoverTheme.sectionLabel())
                    .foregroundStyle(PopoverTheme.ink)
                Spacer()
                Text(percentText)
                    .font(PopoverTheme.percent())
                    .foregroundStyle(stale ? PopoverTheme.mutedSoft : PopoverTheme.ink)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(PopoverTheme.hairline.opacity(0.85))
                    if window != nil {
                        Capsule(style: .continuous)
                            .fill(barColor)
                            .frame(width: max(4, geo.size.width * progressValue))
                            .opacity(stale ? 0.55 : 1)
                    }
                }
            }
            .frame(height: 6)

            Text(resetText)
                .font(PopoverTheme.caption())
                .foregroundStyle(PopoverTheme.muted)
        }
    }

    private var percentText: String {
        guard let window else { return "—" }
        return "\(Int(window.utilization.rounded()))%"
    }

    private var progressValue: Double {
        guard let window else { return 0 }
        return min(max(window.utilization / 100.0, 0), 1)
    }

    private var resetText: String {
        guard let window else { return "Not reported" }
        guard let resetsAt = window.resetsAt else { return "Reset time unavailable" }
        return "Resets in \(Self.formatRemaining(until: resetsAt))"
    }

    private var barColor: Color {
        guard let window else { return PopoverTheme.mutedSoft }
        switch UsageColorBand.band(forPeakUtilization: window.utilization) {
        case .green: return PopoverTheme.success
        case .yellow: return PopoverTheme.warning
        case .red: return PopoverTheme.error
        case .neutral: return PopoverTheme.mutedSoft
        }
    }

    static func formatRemaining(until date: Date, now: Date = Date()) -> String {
        let interval = max(date.timeIntervalSince(now), 0)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 48 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
