import Foundation

protocol UsageFetching: Sendable {
    func fetchUsage(accessToken: String) async throws -> UsageResponse
}

/// Exact-host HTTPS client for Anthropic's undocumented OAuth usage endpoint.
actor UsageClient: UsageFetching {
    static let shared = UsageClient()

    static let allowedHost = "api.anthropic.com"
    static let usagePath = "/api/oauth/usage"
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "ClaudeUsageBar/1.0"
    static let maximumRetryAfter: TimeInterval = 300
    static let retryJitterFraction = 0.2

    private let session: URLSession
    private let redirectDelegate: NoRedirectDelegate
    private let maxAttempts: Int
    private let now: @Sendable () -> Date
    private let randomUnit: @Sendable () -> Double
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        configuration: URLSessionConfiguration? = nil,
        maxAttempts: Int = 3,
        now: @escaping @Sendable () -> Date = { Date() },
        randomUnit: @escaping @Sendable () -> Double = {
            Double.random(in: 0...1)
        },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    ) {
        let delegate = NoRedirectDelegate()
        self.redirectDelegate = delegate
        self.maxAttempts = max(1, maxAttempts)
        self.now = now
        self.randomUnit = randomUnit
        self.sleep = sleep
        self.session = UsageClient.makeSession(
            configuration: configuration,
            delegate: delegate
        )
    }

    private static func makeSession(
        configuration: URLSessionConfiguration?,
        delegate: NoRedirectDelegate
    ) -> URLSession {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    enum ClientError: Error, Equatable {
        case disallowedURL
        case invalidResponse
        case httpStatus(Int, retryAfter: TimeInterval?)
        case decoding(String)
        case transport(String)
        case timedOut
        case redirectRefused
    }

    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        let url = try makeAllowlistedURL()
        var lastError: ClientError = .invalidResponse

        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ClientError.invalidResponse
                }

                if (300..<400).contains(http.statusCode) {
                    throw ClientError.redirectRefused
                }

                if http.statusCode == 429 {
                    let retryAfter = parseRetryAfter(http)
                    throw ClientError.httpStatus(429, retryAfter: retryAfter)
                }

                guard (200..<300).contains(http.statusCode) else {
                    throw ClientError.httpStatus(
                        http.statusCode,
                        retryAfter: parseRetryAfter(http)
                    )
                }

                do {
                    let decoder = JSONDecoder()
                    return try decoder.decode(UsageResponse.self, from: data)
                } catch {
                    throw ClientError.decoding(error.localizedDescription)
                }
            } catch let error as ClientError {
                lastError = error
                guard shouldRetry(error), attempt + 1 < maxAttempts else {
                    throw error
                }
                try await sleep(retryDelay(for: error, afterAttempt: attempt + 1))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                try Task.checkCancellation()
                let mapped: ClientError = error.code == .timedOut
                    ? .timedOut
                    : .transport(error.localizedDescription)
                lastError = mapped
                guard attempt + 1 < maxAttempts else {
                    throw mapped
                }
                try await sleep(retryDelay(for: mapped, afterAttempt: attempt + 1))
            } catch {
                let mapped = ClientError.transport(error.localizedDescription)
                lastError = mapped
                guard attempt + 1 < maxAttempts else {
                    throw mapped
                }
                try await sleep(retryDelay(for: mapped, afterAttempt: attempt + 1))
            }
        }

        throw lastError
    }

    func makeAllowlistedURL() throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.allowedHost
        components.path = Self.usagePath
        guard let url = components.url,
              url.host == Self.allowedHost,
              url.scheme == "https",
              url.path == Self.usagePath else {
            throw ClientError.disallowedURL
        }
        return url
    }

    /// Validates an arbitrary URL against the hard allowlist (used by tests / preflight).
    static func isAllowlisted(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host == allowedHost
            && url.path == usagePath
    }

    private func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty,
           value.allSatisfy(\.isWholeNumber),
           let seconds = TimeInterval(value) {
            return min(max(seconds, 1), Self.maximumRetryAfter)
        }

        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return min(max(date.timeIntervalSince(now()), 1), Self.maximumRetryAfter)
            }
        }

        return nil
    }

    private func shouldRetry(_ error: ClientError) -> Bool {
        switch error {
        case .httpStatus(let code, _):
            return code == 408 || (500..<600).contains(code)
        case .transport, .timedOut:
            return true
        case .disallowedURL, .invalidResponse, .decoding, .redirectRefused:
            return false
        }
    }

    private func retryDelay(
        for error: ClientError,
        afterAttempt attempt: Int
    ) -> TimeInterval {
        let base = min(0.25 * pow(2, Double(max(attempt - 1, 0))), 2)
        let unit = min(max(randomUnit(), 0), 1)
        let jitterMultiplier = (1 - Self.retryJitterFraction)
            + (2 * Self.retryJitterFraction * unit)
        let jitteredBackoff = min(base * jitterMultiplier, 2)
        if case .httpStatus(_, let retryAfter?) = error {
            // Retry-After is a server-specified minimum, never a value to jitter downward.
            return max(retryAfter, jitteredBackoff)
        }
        return jitteredBackoff
    }
}
