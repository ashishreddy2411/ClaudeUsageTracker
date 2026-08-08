import Foundation

enum TokenSource: Equatable, Sendable {
    case claudeCode
}

struct ResolvedToken: Equatable, Sendable {
    let accessToken: String
    let source: TokenSource
    let expiresAt: Date?
    let subscriptionType: String?
}

protocol ClaudeCodeCredentialReading: Sendable {
    func readAccessToken() async -> Result<KeychainTokenReader.TokenResult, KeychainTokenReader.ReadError>
}

struct LiveClaudeCodeCredentialReader: ClaudeCodeCredentialReading {
    func readAccessToken() async -> Result<KeychainTokenReader.TokenResult, KeychainTokenReader.ReadError> {
        await KeychainTokenReader.readAccessToken()
    }
}

/// Resolves only the existing Claude Code credential after explicit opt-in.
/// This type never refreshes, stores, mutates, or deletes credentials.
actor TokenProvider {
    enum ProviderError: Error, Equatable {
        case notConnected
        case missingCredentials
        case expiredCredentials
        case unsupportedPlan
        case keychainDenied(status: Int32)
        case keychainFailed(status: Int32)
        case apiKeyOnly
        case parseError
    }

    private let reader: any ClaudeCodeCredentialReading
    private let now: @Sendable () -> Date

    /// Refuse to reuse a cached token this close to its stated expiry, so a long
    /// in-flight request cannot be sent with a credential that expires mid-flight.
    static let expirySafetyMargin: TimeInterval = 120

    /// Process-memory only. Never written to disk, UserDefaults, or logs, and cleared
    /// on disconnect. This is the same residency the token already had while a request
    /// was in flight; caching only extends it to the interval between refreshes.
    private var cached: ResolvedToken?

    init(
        reader: any ClaudeCodeCredentialReading = LiveClaudeCodeCredentialReader(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.now = now
    }

    /// Drops the cached token. Called on disconnect and whenever the server rejects
    /// the credential, so a revoked or rotated token can never be replayed.
    func invalidateCache() {
        cached = nil
    }

    /// True when the cached token is safe to reuse.
    ///
    /// A token with no stated expiry is never reused: without an expiry there is no
    /// basis for reasoning about staleness, so correctness wins over prompt avoidance.
    static func isReusable(
        _ token: ResolvedToken,
        now: Date,
        safetyMargin: TimeInterval = TokenProvider.expirySafetyMargin
    ) -> Bool {
        guard let expiresAt = token.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) > safetyMargin
    }

    /// - Parameter forceReread: bypasses the cache and reads Keychain again. Used after
    ///   a 401 so Claude Code's rotated token is picked up instead of a stale cache hit.
    func resolveAccessToken(
        connectionEnabled: Bool,
        forceReread: Bool = false
    ) async -> Result<ResolvedToken, ProviderError> {
        guard connectionEnabled else {
            // Consent was withdrawn: the token must not outlive it.
            cached = nil
            return .failure(.notConnected)
        }

        if !forceReread, let cached, Self.isReusable(cached, now: now()) {
            return .success(cached)
        }

        // About to replace the cache with a fresh read. Clearing first guarantees that
        // no failure path below can leave a previously-read token in memory.
        cached = nil

        switch await reader.readAccessToken() {
        case .success(let token):
            let resolved = ResolvedToken(
                accessToken: token.accessToken,
                source: .claudeCode,
                expiresAt: token.expiresAt,
                subscriptionType: token.subscriptionType
            )
            // Only retain what we are willing to reuse; an expiry-less token is
            // dropped immediately rather than held in memory for no benefit.
            cached = Self.isReusable(resolved, now: now()) ? resolved : nil
            return .success(resolved)
        case .failure(.itemNotFound), .failure(.emptyPassword):
            return .failure(.missingCredentials)
        case .failure(.expired):
            return .failure(.expiredCredentials)
        case .failure(.unsupportedPlan):
            return .failure(.unsupportedPlan)
        case .failure(.missingOAuth):
            return .failure(.apiKeyOnly)
        case .failure(.keychainDenied(let status)):
            return .failure(.keychainDenied(status: status))
        case .failure(.decodeFailed):
            return .failure(.parseError)
        case .failure(.securityFailed(let status)):
            return .failure(.keychainFailed(status: status))
        }
    }

    nonisolated static func authStatus(from result: Result<ResolvedToken, ProviderError>) -> AuthStatus {
        switch result {
        case .success(let token):
            return .ready(source: token.source)
        case .failure(.notConnected):
            return .disconnected
        case .failure(.missingCredentials):
            return .credentialsMissing
        case .failure(.expiredCredentials):
            return .credentialsExpired
        case .failure(.unsupportedPlan):
            return .unsupportedPlan
        case .failure(.apiKeyOnly):
            return .apiKeyOnly
        case .failure(.keychainDenied(let status)):
            return .keychainDenied(status: status)
        case .failure(.keychainFailed(let status)):
            return .keychainError(status: status)
        case .failure(.parseError):
            return .parseError
        }
    }
}

enum ClaudeCodeSetup {
    /// ClaudeUsageBar never discovers or executes a Claude Code binary.
    /// Authentication remains an explicit, external Claude Code action.
    static let documentationURL = URL(string: "https://code.claude.com/docs/en/quickstart#step-2-log-in-to-your-account")!
}
