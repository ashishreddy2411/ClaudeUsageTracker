import Foundation
import XCTest
@testable import ClaudeUsageBar

final class UsageClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testProductionClientBuildsRequestAndDecodesUsage() async throws {
        let data = """
        {
          "five_hour": { "utilization": 12.0 },
          "seven_day": { "utilization": 34.0 }
        }
        """.data(using: .utf8)!
        StubURLProtocol.enqueue(.response(status: 200, headers: [:], data: data))
        let client = makeClient(maxAttempts: 1)

        let usage = try await client.fetchUsage(accessToken: "test-credential")

        XCTAssertEqual(usage.fiveHour?.utilization, 12)
        XCTAssertEqual(usage.sevenDay?.utilization, 34)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(StubURLProtocol.authorizationHeaders, ["Bearer test-credential"])
    }

    func testRateLimitReturnsImmediatelyAndCapsDeltaSeconds() async {
        StubURLProtocol.enqueue(
            .response(
                status: 429,
                headers: ["Retry-After": "900"],
                data: Data()
            )
        )
        let sleeps = SleepRecorder()
        let client = makeClient(maxAttempts: 3, sleeps: sleeps)

        do {
            _ = try await client.fetchUsage(accessToken: "test-credential")
            XCTFail("Expected rate limit")
        } catch let error as UsageClient.ClientError {
            XCTAssertEqual(
                error,
                .httpStatus(429, retryAfter: UsageClient.maximumRetryAfter)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let recordedSleeps = await sleeps.values()
        XCTAssertEqual(recordedSleeps, [])
    }

    func testRateLimitParsesHTTPDate() async {
        StubURLProtocol.enqueue(
            .response(
                status: 429,
                headers: ["Retry-After": "Thu, 01 Jan 1970 00:02:00 GMT"],
                data: Data()
            )
        )
        let client = makeClient(
            maxAttempts: 3,
            now: { Date(timeIntervalSince1970: 60) }
        )

        do {
            _ = try await client.fetchUsage(accessToken: "test-credential")
            XCTFail("Expected rate limit")
        } catch let error as UsageClient.ClientError {
            XCTAssertEqual(error, .httpStatus(429, retryAfter: 60))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testServerRetryCountHasNoSleepAfterFinalAttempt() async {
        for _ in 0..<3 {
            StubURLProtocol.enqueue(.response(status: 503, headers: [:], data: Data()))
        }
        let sleeps = SleepRecorder()
        let client = makeClient(maxAttempts: 3, sleeps: sleeps)

        do {
            _ = try await client.fetchUsage(accessToken: "test-credential")
            XCTFail("Expected server error")
        } catch let error as UsageClient.ClientError {
            XCTAssertEqual(error, .httpStatus(503, retryAfter: nil))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 3)
        let recordedSleeps = await sleeps.values()
        XCTAssertEqual(recordedSleeps, [0.25, 0.5])
    }

    func testRetryBackoffUsesInjectedBoundedJitter() async throws {
        StubURLProtocol.enqueue(.response(status: 503, headers: [:], data: Data()))
        StubURLProtocol.enqueue(.response(status: 503, headers: [:], data: Data()))
        StubURLProtocol.enqueue(.response(status: 200, headers: [:], data: validUsageData()))
        let sleeps = SleepRecorder()
        let client = makeClient(
            maxAttempts: 3,
            randomUnit: { 0 },
            sleeps: sleeps
        )

        _ = try await client.fetchUsage(accessToken: "test-credential")

        let recordedSleeps = await sleeps.values()
        XCTAssertEqual(recordedSleeps, [0.2, 0.4])
    }

    func testServerRetryAfterIsNeverJitteredBelowMinimum() async throws {
        StubURLProtocol.enqueue(
            .response(status: 503, headers: ["Retry-After": "1"], data: Data())
        )
        StubURLProtocol.enqueue(.response(status: 200, headers: [:], data: validUsageData()))
        let sleeps = SleepRecorder()
        let client = makeClient(
            maxAttempts: 2,
            randomUnit: { 0 },
            sleeps: sleeps
        )

        _ = try await client.fetchUsage(accessToken: "test-credential")

        let recordedSleeps = await sleeps.values()
        XCTAssertEqual(recordedSleeps, [1])
    }

    func testRedirectIsRefusedWithoutFollowingLocation() async {
        StubURLProtocol.enqueue(
            .response(
                status: 302,
                headers: ["Location": "https://evil.example/collect"],
                data: Data()
            )
        )
        let client = makeClient(maxAttempts: 3)

        do {
            _ = try await client.fetchUsage(accessToken: "test-credential")
            XCTFail("Expected redirect refusal")
        } catch let error as UsageClient.ClientError {
            XCTAssertEqual(error, .redirectRefused)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testTimeoutMapsToStableClientError() async {
        StubURLProtocol.enqueue(.failure(URLError(.timedOut)))
        let client = makeClient(maxAttempts: 1)

        do {
            _ = try await client.fetchUsage(accessToken: "test-credential")
            XCTFail("Expected timeout")
        } catch let error as UsageClient.ClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    private func makeClient(
        maxAttempts: Int,
        now: @escaping @Sendable () -> Date = { Date() },
        randomUnit: @escaping @Sendable () -> Double = { 0.5 },
        sleeps: SleepRecorder? = nil
    ) -> UsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return UsageClient(
            configuration: configuration,
            maxAttempts: maxAttempts,
            now: now,
            randomUnit: randomUnit,
            sleep: { delay in
                await sleeps?.record(delay)
            }
        )
    }

    private func validUsageData() -> Data {
        """
        {
          "five_hour": { "utilization": 12.0 },
          "seven_day": { "utilization": 34.0 }
        }
        """.data(using: .utf8)!
    }
}

private actor SleepRecorder {
    private var recordedValues: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        recordedValues.append(value)
    }

    func values() -> [TimeInterval] {
        recordedValues
    }
}

private enum URLProtocolStub {
    case response(status: Int, headers: [String: String], data: Data)
    case failure(Error)
}

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubs: [URLProtocolStub] = []
    private static var requests = 0
    private static var recordedAuthorizationHeaders: [String] = []

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static var authorizationHeaders: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedAuthorizationHeaders
    }

    static func enqueue(_ stub: URLProtocolStub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs = []
        requests = 0
        recordedAuthorizationHeaders = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let stub: URLProtocolStub
        Self.lock.lock()
        Self.requests += 1
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            Self.recordedAuthorizationHeaders.append(authorization)
        }
        if Self.stubs.isEmpty {
            stub = .failure(URLError(.resourceUnavailable))
        } else {
            stub = Self.stubs.removeFirst()
        }
        Self.lock.unlock()

        switch stub {
        case .response(let status, let headers, let data):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
