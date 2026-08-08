import SwiftUI

/// Explicit Claude Code connection and recovery states.
struct SetupHelpView: View {
    let authStatus: AuthStatus
    let isRefreshing: Bool
    let onConnect: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(supportLine)
                .font(PopoverTheme.bodyCallout())
                .foregroundStyle(PopoverTheme.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if authStatus.needsOfficialSetupGuidance {
                VStack(alignment: .leading, spacing: 10) {
                    Link("Open official Claude Code setup", destination: ClaudeCodeSetup.documentationURL)
                        .buttonStyle(CoralPillButtonStyle())
                    retryButton
                }
            } else if authStatus.showsConnectionButton {
                Button(authStatus.primaryActionTitle, action: onConnect)
                    .buttonStyle(CoralPillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                retryButton
            }

            Text("ClaudeUsageBar reads your existing Claude Code sign-in from macOS Keychain. It never changes or stores your Claude credentials.")
                .font(PopoverTheme.finePrint())
                .foregroundStyle(PopoverTheme.mutedSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopoverTheme.onPrimary)
                }
                Text(isRefreshing ? "Checking…" : "Retry")
            }
        }
        .buttonStyle(CoralPillButtonStyle(disabled: isRefreshing))
        .disabled(isRefreshing)
        .keyboardShortcut(.defaultAction)
    }

    private var supportLine: String {
        switch authStatus {
        case .disconnected, .unknown:
            return "Connect your existing Claude Code sign-in to show session and weekly usage."
        case .signInRequired:
            return "Claude Code isn’t signed in, or its saved sign-in is no longer valid. ClaudeUsageBar will not launch executables."
        case .credentialsMissing:
            return "Claude Code’s saved sign-in was not found. ClaudeUsageBar will not launch executables."
        case .credentialsExpired:
            return "Claude Code’s saved sign-in needs to be renewed outside ClaudeUsageBar."
        case .keychainDenied:
            return "macOS blocked read-only access to Claude Code’s Keychain entry."
        case .keychainError:
            return authStatus.setupMessage
        case .apiKeyOnly, .unsupportedPlan:
            return "Session and weekly bars need Claude Pro, Max, or Team — not an API key."
        case .parseError:
            return "Claude Code’s saved sign-in couldn’t be read."
        case .ready:
            return "Connected to Claude Code."
        }
    }
}

/// Auth OK but no bars yet — same sparse grammar, no card chrome.
struct UsageEmptyStateView: View {
    let title: String
    let message: String
    let isRefreshing: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(PopoverTheme.sectionLabel())
                .foregroundStyle(PopoverTheme.ink)
            Text(message)
                .font(PopoverTheme.bodyCallout())
                .foregroundStyle(PopoverTheme.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(PopoverTheme.coral)
            } else {
                Button("Refresh", action: onRetry)
                    .buttonStyle(CoralPillButtonStyle())
                    .frame(maxWidth: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}
