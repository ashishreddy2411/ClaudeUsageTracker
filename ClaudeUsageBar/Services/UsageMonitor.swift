import Foundation

/// Polls usage on a timer, caches last good payload, and exposes UI state.
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    @Published private(set) var usage: UsageResponse?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStale = false
    @Published private(set) var authStatus: AuthStatus = .unknown
    @Published private(set) var error: MonitorError = .none
    @Published private(set) var peakPercent: Double = 0
    /// Non-nil while manual refreshes are being throttled locally. Drives the UI so a
    /// blocked click is visibly explained rather than silently ignored.
    @Published private(set) var manualRefreshBlockedFor: TimeInterval?

    let preferences: PreferencesStore
    private let client: any UsageFetching
    private let tokenProvider: TokenProvider
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var rateLimitRetryTask: Task<Void, Never>?
    private var rateLimitedUntil: Date?
    private var connectionGeneration: UInt64 = 0
    private let notifications: NotificationService
    private let now: @Sendable () -> Date
    private let rateLimitSleep: @Sendable (TimeInterval) async throws -> Void
    /// Local courtesy throttle for user-initiated refreshes. Timer and startup
    /// refreshes are already bounded and deliberately bypass it.
    private var manualRefreshLimiter: RefreshRateLimiter
    private var manualRefreshCooldownTask: Task<Void, Never>?

    /// Percentage shown in the menu bar. Follows the user's selected window and falls
    /// back to the peak when Anthropic omitted that window, so the menu bar never
    /// displays a fabricated 0% for a bar the API did not return.
    var menuPercent: Double {
        guard let usage else { return peakPercent }
        return usage.utilization(for: preferences.menuPercentSource) ?? peakPercent
    }

    /// Tracks `menuPercent` so the ring's colour and its swept angle always describe
    /// the same window. Threshold notifications still evaluate session and weekly
    /// independently, so narrowing the menu bar to one window hides no alert.
    var colorBand: UsageColorBand {
        if usage == nil && error != .none { return .neutral }
        if isStale && usage == nil { return .neutral }
        if isStale { return .neutral }
        return UsageColorBand.band(forPeakUtilization: menuPercent)
    }

    /// Refresh button label. Surfaces the local throttle instead of silently
    /// disabling the button.
    var refreshButtonTitle: String {
        guard let blocked = manualRefreshBlockedFor, blocked > 0 else { return "Refresh" }
        return "Wait \(max(1, Int(blocked.rounded(.up))))s"
    }

    var canDisconnect: Bool {
        preferences.claudeCodeConnectionEnabled
    }

    init(
        preferences: PreferencesStore? = nil,
        client: any UsageFetching = UsageClient.shared,
        tokenProvider: TokenProvider = TokenProvider(),
        notifications: NotificationService? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        rateLimitSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    ) {
        self.preferences = preferences ?? .shared
        self.client = client
        self.tokenProvider = tokenProvider
        self.notifications = notifications ?? .shared
        self.now = now
        self.rateLimitSleep = rateLimitSleep
        self.manualRefreshLimiter = RefreshRateLimiter(now: now())
    }

    func start() {
        scheduleTimer()
        Task { await refresh(reason: .startup) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        connectionGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
        clearRateLimitRetry()
        clearManualRefreshCooldown()
    }

    func rescheduleTimer() {
        scheduleTimer()
    }

    func refreshNow() {
        Task { await refresh(reason: .manual) }
    }

    /// Persists explicit consent before the first credential read.
    func connect() {
        guard !preferences.claudeCodeConnectionEnabled else {
            refreshNow()
            return
        }
        preferences.claudeCodeConnectionEnabled = true
        connectionGeneration &+= 1
        refreshNow()
    }

    /// Revokes this app's persisted read consent and clears only app state.
    /// Claude Code's Keychain and file credentials are never changed.
    func disconnect() {
        connectionGeneration &+= 1
        preferences.claudeCodeConnectionEnabled = false
        // Revoking consent must drop the in-memory token, not just stop future reads.
        Task { [tokenProvider] in await tokenProvider.invalidateCache() }
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
        clearRateLimitRetry()
        clearManualRefreshCooldown()
        usage = nil
        lastUpdated = nil
        peakPercent = 0
        authStatus = .disconnected
        error = .auth(.disconnected)
        isStale = false
    }

    /// Called when the menu-bar popover opens. Always re-reads credentials on setup /
    /// first-run, then re-fetch.
    func refreshIfStaleOnPopoverOpen() {
        if authStatus.needsSetup || usage == nil || lastUpdated == nil {
            Task { await refresh(reason: .popover) }
            return
        }
        guard shouldRefreshForPopover() else { return }
        Task { await refresh(reason: .popover) }
    }

    private enum RefreshReason {
        case startup, timer, manual, popover

        /// Only these can be triggered repeatedly by clicking, so only these are throttled.
        var isUserInitiated: Bool {
            switch self {
            case .manual, .popover: return true
            case .startup, .timer: return false
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = preferences.refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(reason: .timer)
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func shouldRefreshForPopover() -> Bool {
        guard let lastUpdated else { return true }
        return now().timeIntervalSince(lastUpdated) > preferences.refreshInterval / 2
    }

    private func refresh(reason: RefreshReason) async {
        guard preferences.claudeCodeConnectionEnabled else {
            authStatus = .disconnected
            error = .auth(.disconnected)
            return
        }

        if let rateLimitedUntil, rateLimitedUntil > now() {
            return
        }

        // Shape only what the user can trigger repeatedly. Startup and the 5/10 minute
        // timer are already bounded, and throttling them would stall the app.
        if reason.isUserInitiated {
            guard manualRefreshLimiter.allow(now: now()) else {
                beginManualRefreshCooldown(
                    manualRefreshLimiter.retryDelay(now: now())
                )
                return
            }
            clearManualRefreshCooldown()
        }

        if let refreshTask {
            await refreshTask.value
            return
        }

        let id = UUID()
        let generation = connectionGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation)
        }
        refreshID = id
        refreshTask = task
        isRefreshing = true
        await task.value
        if refreshID == id {
            refreshTask = nil
            refreshID = nil
            isRefreshing = false
        }
    }

    func refreshForTesting() async {
        await refresh(reason: .manual)
    }

    private func performRefresh(generation: UInt64) async {
        guard isCurrent(generation) else { return }

        let tokenResult = await tokenProvider.resolveAccessToken(connectionEnabled: true)
        guard isCurrent(generation) else { return }
        let status = TokenProvider.authStatus(from: tokenResult)
        authStatus = status

        guard case .success(let token) = tokenResult else {
            error = .auth(status)
            isStale = usage != nil
            return
        }

        do {
            let response = try await client.fetchUsage(accessToken: token.accessToken)
            guard isCurrent(generation) else { return }
            applySuccessfulUsage(response)
        } catch let clientError as UsageClient.ClientError {
            guard isCurrent(generation) else { return }
            if case .httpStatus(401, _) = clientError {
                await retryAfterUnauthorized(
                    rejectedToken: token.accessToken,
                    generation: generation
                )
            } else {
                applyClientError(clientError, generation: generation)
                updateStaleFlag()
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(generation) else { return }
            self.error = .network(error.localizedDescription)
            updateStaleFlag()
        }
    }

    /// ClaudeUsageBar never refreshes Claude Code credentials. A 401 causes one
    /// fresh Keychain read and one retry only when Claude Code rotated the access token.
    private func retryAfterUnauthorized(
        rejectedToken: String,
        generation: UInt64
    ) async {
        // Bypass the cache: the server rejected this token, so only a fresh Keychain
        // read can surface the token Claude Code rotated to.
        let reread = await tokenProvider.resolveAccessToken(
            connectionEnabled: true,
            forceReread: true
        )
        guard isCurrent(generation) else { return }

        let replacement: ResolvedToken
        switch reread {
        case .success(let token):
            replacement = token
        case .failure:
            applyAuthFailure(TokenProvider.authStatus(from: reread))
            return
        }

        guard replacement.accessToken != rejectedToken else {
            requireClaudeCodeSignIn()
            return
        }

        do {
            let response = try await client.fetchUsage(accessToken: replacement.accessToken)
            guard isCurrent(generation) else { return }
            applySuccessfulUsage(response)
        } catch is CancellationError {
            return
        } catch let clientError as UsageClient.ClientError {
            guard isCurrent(generation) else { return }
            if case .httpStatus(401, _) = clientError {
                requireClaudeCodeSignIn()
            } else {
                applyClientError(clientError, generation: generation)
                updateStaleFlag()
            }
        } catch {
            guard isCurrent(generation) else { return }
            self.error = .network(error.localizedDescription)
            updateStaleFlag()
        }
    }

    private func requireClaudeCodeSignIn() {
        applyAuthFailure(.signInRequired)
    }

    private func applyAuthFailure(_ status: AuthStatus) {
        authStatus = status
        error = .auth(status)
        isStale = usage != nil
    }

    /// Holds the button in its "Wait Ns" state, then re-enables it. Without this the
    /// throttle would latch and the button would never recover.
    private func beginManualRefreshCooldown(_ delay: TimeInterval) {
        manualRefreshBlockedFor = delay
        manualRefreshCooldownTask?.cancel()
        guard delay > 0 else {
            manualRefreshBlockedFor = nil
            return
        }
        manualRefreshCooldownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.rateLimitSleep(delay)
            } catch {
                return
            }
            self.manualRefreshBlockedFor = nil
            self.manualRefreshCooldownTask = nil
        }
    }

    private func clearManualRefreshCooldown() {
        manualRefreshCooldownTask?.cancel()
        manualRefreshCooldownTask = nil
        manualRefreshBlockedFor = nil
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == connectionGeneration && preferences.claudeCodeConnectionEnabled
    }

    private func applySuccessfulUsage(_ response: UsageResponse) {
        // Anthropic returned OK but no session/weekly windows → plan doesn't expose bars.
        guard response.hasDisplayableWindows else {
            authStatus = .unsupportedPlan
            error = .auth(.unsupportedPlan)
            // Do not invent empty 0% bars.
            if usage == nil {
                updateStaleFlag()
            } else {
                isStale = true
            }
            return
        }

        usage = response
        lastUpdated = now()
        peakPercent = response.peakUtilization
        error = .none
        isStale = false
        clearRateLimitRetry()
        preferences.hasCompletedFirstRun = true
        notifications.evaluate(
            usage: usage!,
            preferences: preferences
        )
    }

    private func applyClientError(
        _ clientError: UsageClient.ClientError,
        generation: UInt64
    ) {
        switch clientError {
        case .httpStatus(401, _):
            requireClaudeCodeSignIn()
        case .httpStatus(403, _):
            error = .auth(.unsupportedPlan)
            authStatus = .unsupportedPlan
        case .httpStatus(429, let retryAfter):
            error = .rateLimited(retryAfter: retryAfter)
            scheduleRateLimitRetry(after: retryAfter, generation: generation)
        case .httpStatus(let code, _):
            error = .server(code)
        case .decoding(let detail):
            error = .decoding(detail)
        case .transport(let message):
            error = .network(message)
        case .timedOut:
            error = .network("The request timed out")
        case .disallowedURL, .invalidResponse, .redirectRefused:
            error = .network("Invalid request configuration")
        }
    }

    private func scheduleRateLimitRetry(
        after retryAfter: TimeInterval?,
        generation: UInt64
    ) {
        let delay = min(max(retryAfter ?? 30, 1), UsageClient.maximumRetryAfter)
        rateLimitedUntil = now().addingTimeInterval(delay)
        rateLimitRetryTask?.cancel()
        rateLimitRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.rateLimitSleep(delay)
            } catch {
                return
            }
            guard self.isCurrent(generation) else { return }
            self.rateLimitedUntil = nil
            self.rateLimitRetryTask = nil
            await self.refresh(reason: .timer)
        }
    }

    private func clearRateLimitRetry() {
        rateLimitRetryTask?.cancel()
        rateLimitRetryTask = nil
        rateLimitedUntil = nil
    }

    private func updateStaleFlag() {
        guard let lastUpdated else {
            isStale = true
            return
        }
        isStale = now().timeIntervalSince(lastUpdated) > preferences.refreshInterval * 2
    }
}


/// Shapes user-initiated refreshes so a burst of clicks cannot become a burst of
/// requests against Anthropic's undocumented usage endpoint.
///
/// ## Why a token bucket
/// A debounce would delay the first click until the user stopped clicking, which makes
/// a refresh button feel broken. A fixed cooldown would reject legitimate back-to-back
/// checks. A token bucket lets the first clicks through immediately, then degrades to a
/// steady refill rate -- the standard shape for client-side request smoothing.
///
/// This is a courtesy limit layered *on top of* the server's 429 handling, not a
/// replacement for it. The server remains the authority.
struct RefreshRateLimiter {
    /// Clicks allowed back-to-back before throttling engages.
    let capacity: Double
    /// Seconds to earn one more refresh.
    let refillInterval: TimeInterval

    private var tokens: Double
    private var lastRefill: Date

    init(capacity: Double = 3, refillInterval: TimeInterval = 20, now: Date) {
        self.capacity = capacity
        self.refillInterval = refillInterval
        self.tokens = capacity
        self.lastRefill = now
    }

    private mutating func refill(now: Date) {
        let elapsed = now.timeIntervalSince(lastRefill)
        // A clock that moves backwards (NTP correction, sleep) must not mint tokens.
        guard elapsed > 0 else {
            lastRefill = now
            return
        }
        tokens = min(capacity, tokens + elapsed / refillInterval)
        lastRefill = now
    }

    /// Consumes a token when one is available.
    mutating func allow(now: Date) -> Bool {
        refill(now: now)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Seconds until the next refresh is permitted; zero when one is available now.
    mutating func retryDelay(now: Date) -> TimeInterval {
        refill(now: now)
        guard tokens < 1 else { return 0 }
        return (1 - tokens) * refillInterval
    }
}
