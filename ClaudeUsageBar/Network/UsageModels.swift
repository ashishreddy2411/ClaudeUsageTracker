import Foundation

/// Response from `GET https://api.anthropic.com/api/oauth/usage`.
/// Values come only from Anthropic — never invent utilization percentages.
struct UsageResponse: Codable, Equatable, Sendable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var sevenDayOpus: UsageWindow?
    var sevenDaySonnet: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    init(
        fiveHour: UsageWindow? = nil,
        sevenDay: UsageWindow? = nil,
        sevenDayOpus: UsageWindow? = nil,
        sevenDaySonnet: UsageWindow? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try Self.decodeWindow(from: container, forKey: .fiveHour)
        sevenDay = try Self.decodeWindow(from: container, forKey: .sevenDay)
        sevenDayOpus = try Self.decodeWindow(from: container, forKey: .sevenDayOpus)
        sevenDaySonnet = try Self.decodeWindow(from: container, forKey: .sevenDaySonnet)
    }

    /// True when Anthropic returned at least one of the bars we display.
    var hasDisplayableWindows: Bool {
        fiveHour != nil || sevenDay != nil
    }

    /// Peak utilization across the session and weekly bars shown in the UI.
    /// Only considers windows Anthropic actually returned.
    var peakUtilization: Double {
        max(fiveHour?.utilization ?? 0, sevenDay?.utilization ?? 0)
    }

    /// Utilization for the window the menu bar is configured to report.
    ///
    /// Returns nil when Anthropic omitted the requested window, so callers fall back
    /// to the peak instead of displaying a fabricated 0%.
    func utilization(for source: MenuPercentSource) -> Double? {
        switch source {
        case .peak:
            return hasDisplayableWindows ? peakUtilization : nil
        case .session:
            return fiveHour?.utilization
        case .weekly:
            return sevenDay?.utilization
        }
    }

    /// Soft-decode a window: missing/null → nil; present without `utilization` → nil
    /// (never invent 0%). Other decode issues still throw.
    private static func decodeWindow(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UsageWindow? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else {
            return nil
        }
        let nested = try container.nestedContainer(keyedBy: UsageWindow.CodingKeys.self, forKey: key)
        guard let utilization = try nested.decodeIfPresent(Double.self, forKey: .utilization) else {
            return nil
        }
        var window = UsageWindow(utilization: utilization, resetsAt: nil)
        if let raw = try nested.decodeIfPresent(String.self, forKey: .resetsAt) {
            window.resetsAt = UsageWindow.parseDate(raw)
        }
        return window
    }
}

struct UsageWindow: Codable, Equatable, Sendable {
    var utilization: Double
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double, resetsAt: Date? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Require an explicit utilization from Anthropic — never default to 0.
        utilization = try container.decode(Double.self, forKey: .utilization)
        if let raw = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = Self.parseDate(raw)
        } else {
            resetsAt = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(utilization, forKey: .utilization)
        if let resetsAt {
            try container.encode(ISO8601DateFormatter.fractional.string(from: resetsAt), forKey: .resetsAt)
        }
    }

    static func parseDate(_ raw: String) -> Date? {
        if let date = ISO8601DateFormatter.fractional.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter.standard.date(from: raw)
    }
}

extension ISO8601DateFormatter {
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Minimal read-only view of Claude Code's Keychain payload.
/// Unknown fields, including refresh credentials, are deliberately not decoded.
struct ClaudeCredentialsBlob: Codable, Equatable, Sendable {
    var claudeAiOauth: ClaudeOAuthCredentials?
}

struct ClaudeOAuthCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var expiresAt: Double?
    var subscriptionType: String?

    /// `expiresAt` is epoch milliseconds (Claude Code) or seconds — normalize both.
    /// Missing or non-positive values mean “unknown expiry” (let the API decide).
    var expirationDate: Date? {
        guard let expiresAt, expiresAt > 0 else { return nil }
        if expiresAt > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: expiresAt / 1000)
        }
        return Date(timeIntervalSince1970: expiresAt)
    }

    var isExpired: Bool {
        guard let expirationDate else { return false }
        return Date() >= expirationDate.addingTimeInterval(-60)
    }
}

/// Plan eligibility for session + weekly bars (Pro / Max / Team seat / Enterprise seat).
/// Official: Settings → Usage shows five-hour + weekly for those plans.
enum PlanEligibility: Equatable, Sendable {
    case eligible
    case unsupported
    case unknown

    static func from(subscriptionType: String?) -> PlanEligibility {
        guard let raw = subscriptionType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty else {
            return .unknown
        }
        let unsupported = ["free", "none", "api", "apikey", "api_key"]
        if unsupported.contains(raw) {
            return .unsupported
        }
        // Known paid / seat plans that expose session + weekly in Settings → Usage.
        let eligibleTokens = ["pro", "max", "team", "enterprise"]
        if eligibleTokens.contains(where: { raw == $0 || raw.contains($0) }) {
            return .eligible
        }
        return .unknown
    }
}

enum UsageColorBand: Equatable, Sendable {
    case green
    case yellow
    case red
    case neutral

    static func band(forPeakUtilization percent: Double) -> UsageColorBand {
        if percent < 50 { return .green }
        if percent < 75 { return .yellow }
        return .red
    }
}

enum AuthStatus: Equatable, Sendable {
    case unknown
    /// Non-secret source label only; credential bytes never enter observable state.
    case ready(source: TokenSource = .claudeCode)
    case disconnected
    case signInRequired
    case credentialsMissing
    case credentialsExpired
    case keychainDenied(status: Int32)
    case keychainError(status: Int32)
    case apiKeyOnly
    case unsupportedPlan
    case parseError

    var needsSetup: Bool {
        switch self {
        case .ready:
            return false
        default:
            return true
        }
    }

    var showsConnectionButton: Bool {
        switch self {
        case .disconnected, .unknown:
            return true
        default:
            return false
        }
    }

    var needsOfficialSetupGuidance: Bool {
        switch self {
        case .signInRequired, .credentialsMissing, .credentialsExpired:
            return true
        case .unknown, .ready, .disconnected, .keychainDenied, .keychainError,
             .apiKeyOnly, .unsupportedPlan, .parseError:
            return false
        }
    }

    var setupSymbol: String {
        switch self {
        case .keychainDenied:
            return "key.fill"
        case .keychainError:
            return "exclamationmark.lock"
        case .signInRequired, .credentialsMissing, .credentialsExpired:
            return "terminal"
        case .disconnected:
            return "person.crop.circle"
        case .unknown:
            return "sparkles"
        case .apiKeyOnly, .unsupportedPlan:
            return "creditcard.trianglebadge.exclamationmark"
        case .parseError:
            return "exclamationmark.triangle"
        case .ready:
            return "checkmark.circle"
        }
    }

    var setupTitle: String {
        switch self {
        case .disconnected, .unknown:
            return "Connect Claude Code"
        case .signInRequired:
            return "Complete Claude Code sign-in"
        case .credentialsMissing:
            return "Claude Code sign-in not found"
        case .credentialsExpired:
            return "Claude Code sign-in needs renewal"
        case .keychainDenied:
            return "Allow Keychain access"
        case .keychainError:
            return "Couldn’t access Keychain"
        case .apiKeyOnly, .unsupportedPlan:
            return "Plan doesn't include usage bars"
        case .parseError:
            return "Couldn't read saved login"
        case .ready:
            return "Connected"
        }
    }

    var setupMessage: String {
        switch self {
        case .disconnected, .unknown:
            return "ClaudeUsageBar reads your existing Claude Code sign-in from macOS Keychain. It never changes or stores your Claude credentials."
        case .signInRequired:
            return "Use Anthropic’s official setup instructions to install or sign in to Claude Code. Return here and click Retry after sign-in."
        case .credentialsMissing:
            return "Claude Code’s saved sign-in was not found. Follow Anthropic’s official setup instructions, then return here and click Retry."
        case .credentialsExpired:
            return "Claude Code’s saved sign-in is no longer valid. Sign in again using Anthropic’s official setup instructions, then click Retry."
        case .keychainDenied(let status):
            return "macOS denied read-only access to Claude Code’s Keychain entry (status \(status)). Retry and approve the prompt."
        case .keychainError(let status):
            return "macOS Keychain returned status \(status). Retry the read; ClaudeUsageBar will not start authentication."
        case .apiKeyOnly:
            return "API keys don’t expose session and weekly bars. Use Claude Pro, Max, or Team."
        case .unsupportedPlan:
            return "Session and weekly bars need Claude Pro, Max, or Team."
        case .parseError:
            return "Claude Code’s saved sign-in couldn’t be read. Sign in again using Claude Code."
        case .ready:
            return "Connected to Claude Code."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .signInRequired, .credentialsMissing, .credentialsExpired:
            return "Open official setup"
        case .keychainDenied, .keychainError, .parseError:
            return "Retry Keychain Access"
        case .disconnected, .unknown:
            return "Connect Claude Code"
        case .apiKeyOnly, .unsupportedPlan, .ready:
            return "Try Again"
        }
    }
}

enum MonitorError: Equatable, Sendable {
    case none
    case auth(AuthStatus)
    case network(String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(Int)
    case decoding(String)

    var isAuthRelated: Bool {
        switch self {
        case .auth:
            return true
        default:
            return false
        }
    }

    /// Compact banner for the usage view when we keep last-known bars.
    var bannerMessage: String? {
        switch self {
        case .none:
            return nil
        case .auth(let status):
            switch status {
            case .signInRequired, .credentialsExpired:
                return "Claude Code sign-in is no longer valid. Sign in with Claude Code to reconnect."
            case .credentialsMissing:
                return "Claude Code sign-in was not found. Complete official setup, then retry."
            case .disconnected:
                return "Disconnected from ClaudeUsageBar."
            case .keychainDenied:
                return "Read-only Keychain access was denied."
            case .keychainError:
                return status.setupMessage
            default:
                return status.setupMessage
            }
        case .network:
            return "Connection issue. Showing last known usage if available."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                let minutes = max(1, Int(retryAfter / 60))
                return "Temporarily rate-limited. Retrying in about \(minutes) min. Showing last known usage if available."
            }
            return "Temporarily rate-limited. Showing last known usage if available."
        case .server:
            return "Anthropic is temporarily unavailable. Showing last known usage if available."
        case .decoding:
            return "Unexpected response from Anthropic. Showing last known usage if available."
        }
    }

    /// Empty-state copy when credentials work but we have no cached bars yet.
    var emptyStateTitle: String? {
        switch self {
        case .none:
            return "Loading usage…"
        case .network:
            return "Connection issue"
        case .rateLimited:
            return "Temporarily rate-limited"
        case .server:
            return "Anthropic unavailable"
        case .decoding:
            return "Unexpected response"
        case .auth:
            return nil
        }
    }

    var emptyStateMessage: String? {
        switch self {
        case .none:
            return "Fetching your session and weekly usage from Anthropic."
        case .network:
            return "Check your connection, then click Refresh. Numbers only come from Anthropic."
        case .rateLimited:
            return "Too many requests. Wait a moment, then click Refresh."
        case .server(let code):
            return "Anthropic returned HTTP \(code). Try again in a bit."
        case .decoding:
            return "The usage response couldn't be read. Try Refresh; if it persists, sign in again with Claude Code."
        case .auth:
            return nil
        }
    }
}
