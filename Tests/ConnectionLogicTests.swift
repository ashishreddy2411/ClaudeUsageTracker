import Foundation
import XCTest
@testable import ClaudeUsageBar

final class ConnectionLogicTests: XCTestCase {
    @MainActor
    func testConnectPersistsConsentBeforeCredentialRead() async {
        let preferences = makePreferences(connected: false)
        let reader = MockCredentialReader(
            results: [.success(token("credential-a"))],
            delayNanoseconds: 50_000_000
        )
        let monitor = makeMonitor(preferences: preferences, reader: reader)

        monitor.connect()

        XCTAssertTrue(preferences.claudeCodeConnectionEnabled)
        try? await Task.sleep(nanoseconds: 120_000_000)
        let reads = await reader.readCount()
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testDisconnectedRefreshNeverReadsCredentials() async {
        let preferences = makePreferences(connected: false)
        let reader = MockCredentialReader(results: [.success(token("credential-a"))])
        let monitor = makeMonitor(preferences: preferences, reader: reader)

        await monitor.refreshForTesting()

        let reads = await reader.readCount()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(monitor.authStatus, .disconnected)
        XCTAssertNil(monitor.usage)
    }

    @MainActor
    func testPersistedConnectionReadsAndFetchesUsage() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(results: [.success(token("credential-a"))])
        let client = MockUsageClient(results: [.success(usage(21))])
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client
        )

        await monitor.refreshForTesting()

        let reads = await reader.readCount()
        let fetches = await client.fetchCount()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(monitor.usage?.fiveHour?.utilization, 21)
        XCTAssertEqual(monitor.authStatus, .ready(source: .claudeCode))
    }

    @MainActor
    func testTimerManualAndPopoverRefreshesCoalesce() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(
            results: [.success(token("credential-a"))],
            delayNanoseconds: 80_000_000
        )
        let client = MockUsageClient(
            results: [.success(usage(32))],
            delayNanoseconds: 80_000_000
        )
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client
        )

        let first = Task { await monitor.refreshForTesting() }
        let second = Task { await monitor.refreshForTesting() }
        let third = Task { await monitor.refreshForTesting() }
        await first.value
        await second.value
        await third.value

        let reads = await reader.readCount()
        let fetches = await client.fetchCount()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(monitor.usage?.fiveHour?.utilization, 32)
    }

    @MainActor
    func testUnauthorizedRereadsKeychainAndRetriesRotatedCredentialOnce() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(results: [
            .success(token("credential-a")),
            .success(token("credential-b")),
        ])
        let client = MockUsageClient(results: [
            .failure(.httpStatus(401, retryAfter: nil)),
            .success(usage(44)),
        ])
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client
        )

        await monitor.refreshForTesting()

        let reads = await reader.readCount()
        let fetches = await client.fetchCount()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(monitor.usage?.fiveHour?.utilization, 44)
        XCTAssertEqual(monitor.authStatus, .ready(source: .claudeCode))
    }

    @MainActor
    func testUnauthorizedUnchangedCredentialRequiresClaudeCodeSignIn() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(results: [
            .success(token("credential-a")),
            .success(token("credential-a")),
        ])
        let client = MockUsageClient(results: [
            .failure(.httpStatus(401, retryAfter: nil)),
        ])
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client
        )

        await monitor.refreshForTesting()

        let reads = await reader.readCount()
        let fetches = await client.fetchCount()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(monitor.authStatus, .signInRequired)
        XCTAssertNil(monitor.usage)
    }

    @MainActor
    func testUnauthorizedRereadPreservesPreciseCredentialFailure() async {
        let cases: [(KeychainTokenReader.ReadError, AuthStatus)] = [
            (.itemNotFound, .credentialsMissing),
            (.expired, .credentialsExpired),
            (.keychainDenied(status: -25293), .keychainDenied(status: -25293)),
            (.securityFailed(status: -9999), .keychainError(status: -9999)),
        ]

        for (readError, expectedStatus) in cases {
            let preferences = makePreferences(connected: true)
            let reader = MockCredentialReader(results: [
                .success(token("credential-a")),
                .failure(readError),
            ])
            let client = MockUsageClient(results: [
                .failure(.httpStatus(401, retryAfter: nil)),
            ])
            let monitor = makeMonitor(
                preferences: preferences,
                reader: reader,
                client: client
            )

            await monitor.refreshForTesting()

            let reads = await reader.readCount()
            let fetches = await client.fetchCount()
            XCTAssertEqual(monitor.authStatus, expectedStatus, "reread error: \(readError)")
            XCTAssertEqual(monitor.error, .auth(expectedStatus), "reread error: \(readError)")
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(fetches, 1)
        }
    }

    @MainActor
    func testRateLimitSurfacesWithoutBlockingRefresh() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(results: [.success(token("credential-a"))])
        let client = MockUsageClient(results: [
            .failure(.httpStatus(429, retryAfter: 120)),
        ])
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client
        )

        await monitor.refreshForTesting()

        let fetches = await client.fetchCount()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(monitor.error, .rateLimited(retryAfter: 120))
        XCTAssertFalse(monitor.isRefreshing)
        monitor.disconnect()
    }

    @MainActor
    func testRateLimitSchedulesAndPerformsMonitorRetry() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(results: [.success(token("credential-a"))])
        let client = MockUsageClient(results: [
            .failure(.httpStatus(429, retryAfter: 12)),
            .success(usage(37)),
        ])
        let sleeper = ControlledRateLimitSleeper()
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client,
            rateLimitSleep: { delay in
                try await sleeper.sleep(delay)
            }
        )

        await monitor.refreshForTesting()
        await sleeper.waitUntilSleeping()

        let recordedDelay = await sleeper.recordedDelay()
        XCTAssertEqual(recordedDelay, 12)
        XCTAssertEqual(monitor.error, .rateLimited(retryAfter: 12))

        await sleeper.resume()
        await waitUntil { await client.fetchCount() == 2 }

        XCTAssertEqual(monitor.usage?.fiveHour?.utilization, 37)
        XCTAssertEqual(monitor.error, .none)
        monitor.stop()
    }

    @MainActor
    func testDisconnectWinsOverLateCredentialAndUsageResults() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(results: [.success(token("credential-a"))])
        let client = MockUsageClient(
            results: [.success(usage(91))],
            delayNanoseconds: 150_000_000,
            ignoreCancellation: true
        )
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client
        )

        let refresh = Task { await monitor.refreshForTesting() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        monitor.disconnect()
        await refresh.value

        XCTAssertFalse(preferences.claudeCodeConnectionEnabled)
        XCTAssertEqual(monitor.authStatus, .disconnected)
        XCTAssertNil(monitor.usage)
        XCTAssertNil(monitor.lastUpdated)
        XCTAssertFalse(monitor.isRefreshing)
    }

    @MainActor
    func testDisconnectWinsOverDelayedCredentialRead() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(
            results: [.success(token("credential-a"))],
            delayNanoseconds: 150_000_000,
            ignoreCancellation: true
        )
        let client = MockUsageClient(results: [.success(usage(88))])
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client
        )

        let refresh = Task { await monitor.refreshForTesting() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        monitor.disconnect()
        await refresh.value

        let fetches = await client.fetchCount()
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(monitor.authStatus, .disconnected)
        XCTAssertNil(monitor.usage)
        XCTAssertFalse(monitor.isRefreshing)
    }

    @MainActor
    func testMissingCredentialsKeepsConsentAndUsesOfficialSetupLink() async {
        let preferences = makePreferences(connected: false)
        let reader = MockCredentialReader(results: [.failure(.itemNotFound)])
        let monitor = makeMonitor(preferences: preferences, reader: reader)

        monitor.connect()
        await monitor.refreshForTesting()

        XCTAssertTrue(preferences.claudeCodeConnectionEnabled)
        XCTAssertEqual(monitor.authStatus, .credentialsMissing)
        XCTAssertEqual(ClaudeCodeSetup.documentationURL.scheme, "https")
        XCTAssertEqual(ClaudeCodeSetup.documentationURL.host, "code.claude.com")
        XCTAssertTrue(ClaudeCodeSetup.documentationURL.path.contains("quickstart"))
    }

    @MainActor
    func testKeychainDenialRetryOnlyRereadsCredential() async {
        let preferences = makePreferences(connected: true)
        let reader = MockCredentialReader(results: [
            .failure(.keychainDenied(status: -25293)),
            .failure(.keychainDenied(status: -25293)),
        ])
        let client = MockUsageClient(results: [.success(usage(50))])
        let monitor = makeMonitor(
            preferences: preferences,
            reader: reader,
            client: client
        )

        await monitor.refreshForTesting()
        await monitor.refreshForTesting()

        let reads = await reader.readCount()
        let fetches = await client.fetchCount()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(monitor.authStatus, .keychainDenied(status: -25293))
    }

    func testAuthenticationRouteIsDocumentationOnly() {
        XCTAssertEqual(
            ClaudeCodeSetup.documentationURL.absoluteString,
            "https://code.claude.com/docs/en/quickstart#step-2-log-in-to-your-account"
        )
    }

    @MainActor
    func testLaunchAtLoginRegistrationFailureReconcilesToggleOff() {
        let suite = "LaunchAtLoginTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let controller = FakeLaunchAtLoginController(
            status: .disabled,
            registrationError: TestLaunchAtLoginError.failed
        )
        let preferences = PreferencesStore(
            defaults: defaults,
            launchAtLoginController: controller
        )

        preferences.setLaunchAtLogin(true)

        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertNotNil(preferences.launchAtLoginError)
    }

    @MainActor
    func testLaunchAtLoginReconcilesToSystemStatus() {
        let suite = "LaunchAtLoginTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "launchAtLogin")
        let controller = FakeLaunchAtLoginController(status: .enabled)
        let preferences = PreferencesStore(
            defaults: defaults,
            launchAtLoginController: controller
        )

        XCTAssertTrue(preferences.launchAtLogin)
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
    }

    func testCredentialParserIgnoresRefreshCredentialField() {
        let fixture = """
        {
          "claudeAiOauth": {
            "accessToken": "credential-a",
            "refreshToken": "ignored-by-this-app",
            "expiresAt": 4102444800000,
            "subscriptionType": "pro"
          }
        }
        """

        guard case .success(let parsed) = KeychainTokenReader.parseCredentialsJSON(fixture) else {
            return XCTFail("expected fixture to decode")
        }
        XCTAssertEqual(parsed.subscriptionType, "pro")
        XCTAssertNotNil(parsed.expiresAt)
    }

    @MainActor
    private func makePreferences(connected: Bool) -> PreferencesStore {
        let suite = "ConnectionLogicTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = PreferencesStore(
            defaults: defaults,
            launchAtLoginController: FakeLaunchAtLoginController(status: .disabled)
        )
        preferences.claudeCodeConnectionEnabled = connected
        return preferences
    }

    @MainActor
    private func makeMonitor(
        preferences: PreferencesStore,
        reader: MockCredentialReader,
        client: MockUsageClient? = nil,
        rateLimitSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    ) -> UsageMonitor {
        return UsageMonitor(
            preferences: preferences,
            client: client ?? MockUsageClient(results: [.success(usage(1))]),
            tokenProvider: TokenProvider(reader: reader),
            rateLimitSleep: rateLimitSleep
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<1_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }

    private func token(_ value: String) -> KeychainTokenReader.TokenResult {
        KeychainTokenReader.TokenResult(
            accessToken: value,
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            subscriptionType: "pro"
        )
    }

    private func usage(_ percent: Double) -> UsageResponse {
        UsageResponse(fiveHour: UsageWindow(utilization: percent))
    }
}

private actor ControlledRateLimitSleeper {
    private var delay: TimeInterval?
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(_ delay: TimeInterval) async throws {
        self.delay = delay
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSleeping() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func recordedDelay() -> TimeInterval? {
        delay
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MockCredentialReader: ClaudeCodeCredentialReading {
    private var results: [Result<KeychainTokenReader.TokenResult, KeychainTokenReader.ReadError>]
    private var count = 0
    private let delayNanoseconds: UInt64
    private let ignoreCancellation: Bool

    init(
        results: [Result<KeychainTokenReader.TokenResult, KeychainTokenReader.ReadError>],
        delayNanoseconds: UInt64 = 0,
        ignoreCancellation: Bool = false
    ) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
        self.ignoreCancellation = ignoreCancellation
    }

    func readAccessToken() async -> Result<KeychainTokenReader.TokenResult, KeychainTokenReader.ReadError> {
        count += 1
        if delayNanoseconds > 0 {
            if ignoreCancellation {
                await Task.detached { [delayNanoseconds] in
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }.value
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        if results.count > 1 {
            return results.removeFirst()
        }
        return results[0]
    }

    func readCount() -> Int {
        count
    }
}

private actor MockUsageClient: UsageFetching {
    private var results: [Result<UsageResponse, UsageClient.ClientError>]
    private var count = 0
    private let delayNanoseconds: UInt64
    private let ignoreCancellation: Bool

    init(
        results: [Result<UsageResponse, UsageClient.ClientError>],
        delayNanoseconds: UInt64 = 0,
        ignoreCancellation: Bool = false
    ) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
        self.ignoreCancellation = ignoreCancellation
    }

    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        count += 1
        if delayNanoseconds > 0 {
            if ignoreCancellation {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            } else {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        let result: Result<UsageResponse, UsageClient.ClientError>
        if results.count > 1 {
            result = results.removeFirst()
        } else {
            result = results[0]
        }
        return try result.get()
    }

    func fetchCount() -> Int {
        count
    }
}

private enum TestLaunchAtLoginError: Error {
    case failed
}

private final class FakeLaunchAtLoginController: LaunchAtLoginControlling {
    private var status: LaunchAtLoginRegistrationStatus
    private let registrationError: Error?

    init(
        status: LaunchAtLoginRegistrationStatus,
        registrationError: Error? = nil
    ) {
        self.status = status
        self.registrationError = registrationError
    }

    func registrationStatus() -> LaunchAtLoginRegistrationStatus {
        status
    }

    func setEnabled(_ enabled: Bool) throws {
        if let registrationError {
            throw registrationError
        }
        status = enabled ? .enabled : .disabled
    }
}


/// Covers the in-memory token cache, the local refresh throttle, the menu bar window
/// selection, and the status ring geometry.
final class RefreshAndCacheTests: XCTestCase {

    // MARK: - Token cache

    private func token(
        _ value: String,
        expiresAt: Date?
    ) -> KeychainTokenReader.TokenResult {
        KeychainTokenReader.TokenResult(
            accessToken: value,
            expiresAt: expiresAt,
            subscriptionType: "pro"
        )
    }

    func testSecondResolveReusesCachedTokenWithoutReadingKeychain() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = MockCredentialReader(
            results: [
                .success(token("credential-a", expiresAt: now.addingTimeInterval(3600))),
                .success(token("credential-b", expiresAt: now.addingTimeInterval(3600))),
            ]
        )
        let provider = TokenProvider(reader: reader, now: { now })

        let first = await provider.resolveAccessToken(connectionEnabled: true)
        let second = await provider.resolveAccessToken(connectionEnabled: true)

        XCTAssertEqual(try? first.get().accessToken, "credential-a")
        XCTAssertEqual(try? second.get().accessToken, "credential-a")
        let reads = await reader.readCount()
        XCTAssertEqual(reads, 1, "cached token must not trigger a second Keychain read")
    }

    func testTokenWithoutExpiryIsNeverCached() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = MockCredentialReader(
            results: [
                .success(token("credential-a", expiresAt: nil)),
                .success(token("credential-b", expiresAt: nil)),
            ]
        )
        let provider = TokenProvider(reader: reader, now: { now })

        _ = await provider.resolveAccessToken(connectionEnabled: true)
        let second = await provider.resolveAccessToken(connectionEnabled: true)

        XCTAssertEqual(try? second.get().accessToken, "credential-b")
        let reads = await reader.readCount()
        XCTAssertEqual(reads, 2, "a token with no stated expiry must never be reused")
    }

    func testTokenInsideExpirySafetyMarginIsNotReused() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Expires inside the safety margin, so it must not be reused even though
        // it has not technically expired yet.
        let expiry = now.addingTimeInterval(TokenProvider.expirySafetyMargin - 1)
        let reader = MockCredentialReader(
            results: [
                .success(token("credential-a", expiresAt: expiry)),
                .success(token("credential-b", expiresAt: now.addingTimeInterval(3600))),
            ]
        )
        let provider = TokenProvider(reader: reader, now: { now })

        _ = await provider.resolveAccessToken(connectionEnabled: true)
        let second = await provider.resolveAccessToken(connectionEnabled: true)

        XCTAssertEqual(try? second.get().accessToken, "credential-b")
        let reads = await reader.readCount()
        XCTAssertEqual(reads, 2)
    }

    func testForceRereadBypassesCache() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = MockCredentialReader(
            results: [
                .success(token("credential-a", expiresAt: now.addingTimeInterval(3600))),
                .success(token("credential-b", expiresAt: now.addingTimeInterval(3600))),
            ]
        )
        let provider = TokenProvider(reader: reader, now: { now })

        _ = await provider.resolveAccessToken(connectionEnabled: true)
        let second = await provider.resolveAccessToken(
            connectionEnabled: true,
            forceReread: true
        )

        XCTAssertEqual(try? second.get().accessToken, "credential-b")
        let reads = await reader.readCount()
        XCTAssertEqual(reads, 2, "a 401 must be able to pick up a rotated token")
    }

    func testDisconnectClearsCachedToken() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = MockCredentialReader(
            results: [
                .success(token("credential-a", expiresAt: now.addingTimeInterval(3600))),
                .success(token("credential-b", expiresAt: now.addingTimeInterval(3600))),
            ]
        )
        let provider = TokenProvider(reader: reader, now: { now })

        _ = await provider.resolveAccessToken(connectionEnabled: true)
        await provider.invalidateCache()
        let afterInvalidate = await provider.resolveAccessToken(connectionEnabled: true)

        XCTAssertEqual(try? afterInvalidate.get().accessToken, "credential-b")
        let reads = await reader.readCount()
        XCTAssertEqual(reads, 2)
    }

    func testWithdrawnConsentDropsCachedToken() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = MockCredentialReader(
            results: [
                .success(token("credential-a", expiresAt: now.addingTimeInterval(3600))),
                .success(token("credential-b", expiresAt: now.addingTimeInterval(3600))),
            ]
        )
        let provider = TokenProvider(reader: reader, now: { now })

        _ = await provider.resolveAccessToken(connectionEnabled: true)
        // A disconnected resolve must not merely fail; it must also purge memory.
        _ = await provider.resolveAccessToken(connectionEnabled: false)
        let reconnected = await provider.resolveAccessToken(connectionEnabled: true)

        XCTAssertEqual(try? reconnected.get().accessToken, "credential-b")
        let reads = await reader.readCount()
        XCTAssertEqual(reads, 2)
    }

    // MARK: - Refresh throttle

    func testLimiterAllowsBurstThenBlocks() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var limiter = RefreshRateLimiter(capacity: 3, refillInterval: 20, now: start)

        XCTAssertTrue(limiter.allow(now: start))
        XCTAssertTrue(limiter.allow(now: start))
        XCTAssertTrue(limiter.allow(now: start))
        XCTAssertFalse(limiter.allow(now: start), "fourth rapid refresh must be blocked")
    }

    func testLimiterRefillsOverTime() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var limiter = RefreshRateLimiter(capacity: 3, refillInterval: 20, now: start)
        for _ in 0..<3 { _ = limiter.allow(now: start) }

        XCTAssertFalse(limiter.allow(now: start.addingTimeInterval(19)))
        XCTAssertTrue(limiter.allow(now: start.addingTimeInterval(20)))
    }

    func testLimiterReportsRetryDelay() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var limiter = RefreshRateLimiter(capacity: 1, refillInterval: 20, now: start)
        XCTAssertEqual(limiter.retryDelay(now: start), 0)

        _ = limiter.allow(now: start)
        XCTAssertEqual(limiter.retryDelay(now: start), 20, accuracy: 0.001)
        XCTAssertEqual(limiter.retryDelay(now: start.addingTimeInterval(5)), 15, accuracy: 0.001)
    }

    func testLimiterDoesNotMintTokensWhenClockMovesBackwards() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var limiter = RefreshRateLimiter(capacity: 2, refillInterval: 20, now: start)
        _ = limiter.allow(now: start)
        _ = limiter.allow(now: start)

        // A backwards clock (NTP correction / wake from sleep) must not grant refreshes.
        XCTAssertFalse(limiter.allow(now: start.addingTimeInterval(-600)))
    }

    @MainActor
    func testRapidManualRefreshesStopHittingTheNetwork() async {
        let suite = "RefreshThrottleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = PreferencesStore(
            defaults: defaults,
            launchAtLoginController: FakeLaunchAtLoginController(status: .disabled)
        )
        preferences.claudeCodeConnectionEnabled = true

        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = MockUsageClient(
            results: Array(
                repeating: Result<UsageResponse, UsageClient.ClientError>.success(
                    UsageResponse(fiveHour: UsageWindow(utilization: 10))
                ),
                count: 10
            )
        )
        let reader = MockCredentialReader(
            results: Array(
                repeating: .success(
                    KeychainTokenReader.TokenResult(
                        accessToken: "credential-a",
                        expiresAt: now.addingTimeInterval(3600),
                        subscriptionType: "pro"
                    )
                ),
                count: 10
            )
        )
        let monitor = UsageMonitor(
            preferences: preferences,
            client: client,
            tokenProvider: TokenProvider(reader: reader, now: { now }),
            now: { now },
            rateLimitSleep: { _ in }
        )

        // Ten impatient clicks at the same instant.
        for _ in 0..<10 {
            await monitor.refreshForTesting()
        }

        let fetches = await client.fetchCount()
        XCTAssertLessThanOrEqual(
            fetches,
            3,
            "the local throttle must cap a click burst well below ten requests"
        )
        XCTAssertGreaterThan(fetches, 0, "the first click must still refresh immediately")
    }

    // MARK: - Menu bar window selection

    func testMenuPercentSourceSelectsRequestedWindow() {
        let usage = UsageResponse(
            fiveHour: UsageWindow(utilization: 20),
            sevenDay: UsageWindow(utilization: 80)
        )

        XCTAssertEqual(usage.utilization(for: .session), 20)
        XCTAssertEqual(usage.utilization(for: .weekly), 80)
        XCTAssertEqual(usage.utilization(for: .peak), 80)
    }

    func testMissingWindowReturnsNilRatherThanFakeZero() {
        let sessionOnly = UsageResponse(fiveHour: UsageWindow(utilization: 20))

        XCTAssertNil(sessionOnly.utilization(for: .weekly))
        XCTAssertEqual(sessionOnly.utilization(for: .session), 20)
        XCTAssertNil(UsageResponse().utilization(for: .peak))
    }

    func testMenuPercentSourceRawValuesAreStable() {
        // These strings are persisted in UserDefaults; changing them silently resets
        // every existing user's preference.
        XCTAssertEqual(MenuPercentSource.peak.rawValue, "peak")
        XCTAssertEqual(MenuPercentSource.session.rawValue, "session")
        XCTAssertEqual(MenuPercentSource.weekly.rawValue, "weekly")
    }

    // MARK: - Status ring geometry

    func testRingFractionClampsOutOfRangeAndNonFiniteValues() {
        XCTAssertEqual(UsageRingRenderer.fractionFilled(forPercent: 0), 0)
        XCTAssertEqual(UsageRingRenderer.fractionFilled(forPercent: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(UsageRingRenderer.fractionFilled(forPercent: 100), 1)
        XCTAssertEqual(UsageRingRenderer.fractionFilled(forPercent: 140), 1)
        XCTAssertEqual(UsageRingRenderer.fractionFilled(forPercent: -20), 0)
        XCTAssertEqual(UsageRingRenderer.fractionFilled(forPercent: .nan), 0)
        XCTAssertEqual(UsageRingRenderer.fractionFilled(forPercent: .infinity), 0)
    }

    func testRingImageIsRenderedAtMenuBarSize() {
        let image = UsageRingRenderer.image(percent: 42, band: .green, stale: false)
        XCTAssertEqual(image.size, UsageRingRenderer.canvasSize)
        XCTAssertFalse(image.isTemplate, "band colour must survive system tinting")
    }

    // MARK: - Relative timestamp

    @MainActor
    func testJustRefreshedNeverReadsAsFutureTense() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // A refresh that completed a fraction of a second ago previously rendered as
        // "in 0 sec" because the interval rounded to zero.
        let text = PopoverTheme.relativeUpdatedText(
            for: now.addingTimeInterval(-0.2),
            now: now,
            isStale: false
        )
        XCTAssertEqual(text, "just now")
        XCTAssertFalse(text.hasPrefix("in "))
    }

    @MainActor
    func testClockSkewIntoTheFutureStillReadsAsJustNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = PopoverTheme.relativeUpdatedText(
            for: now.addingTimeInterval(30),
            now: now,
            isStale: false
        )
        XCTAssertEqual(text, "just now")
    }

    @MainActor
    func testOlderTimestampsStillUseRelativeFormatting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = PopoverTheme.relativeUpdatedText(
            for: now.addingTimeInterval(-600),
            now: now,
            isStale: false
        )
        XCTAssertNotEqual(text, "just now")
    }

    @MainActor
    func testStaleSuffixIsPreserved() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = PopoverTheme.relativeUpdatedText(
            for: now.addingTimeInterval(-1),
            now: now,
            isStale: true
        )
        XCTAssertEqual(text, "just now · stale")
    }
}
