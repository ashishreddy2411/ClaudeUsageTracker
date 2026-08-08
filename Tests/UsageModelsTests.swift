import Security
import XCTest
@testable import ClaudeUsageBar

final class UsageModelsTests: XCTestCase {
    func testDecodeFiveHourAndSevenDay() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 33.0,
            "resets_at": "2026-04-11T07:00:00.528743+00:00"
          },
          "seven_day": {
            "utilization": 13.0,
            "resets_at": "2026-04-17T00:59:59.951713+00:00"
          },
          "seven_day_opus": null,
          "seven_day_sonnet": {
            "utilization": 1.0,
            "resets_at": "2026-04-16T03:00:00.951719+00:00"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UsageResponse.self, from: json)
        XCTAssertEqual(decoded.fiveHour?.utilization, 33)
        XCTAssertEqual(decoded.sevenDay?.utilization, 13)
        XCTAssertNil(decoded.sevenDayOpus)
        XCTAssertEqual(decoded.sevenDaySonnet?.utilization, 1)
        XCTAssertEqual(decoded.peakUtilization, 33)
        XCTAssertNotNil(decoded.fiveHour?.resetsAt)
    }

    func testDecodeMissingResetsAt() throws {
        let json = """
        {
          "five_hour": { "utilization": 6.0, "resets_at": null },
          "seven_day": { "utilization": 35.0 }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UsageResponse.self, from: json)
        XCTAssertEqual(decoded.fiveHour?.utilization, 6)
        XCTAssertNil(decoded.fiveHour?.resetsAt)
        XCTAssertEqual(decoded.sevenDay?.utilization, 35)
    }

    func testParseCredentialsJSON() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "credential-fixture",
            "refreshToken": "ignored-fixture",
            "expiresAt": 4102444800000,
            "subscriptionType": "pro"
          }
        }
        """
        let result = KeychainTokenReader.parseCredentialsJSON(json)
        guard case .success(let token) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(token.accessToken, "credential-fixture")
        XCTAssertEqual(token.subscriptionType, "pro")
        XCTAssertNotNil(token.expiresAt)
    }

    func testDecodeMissingUtilizationDoesNotInventZero() throws {
        let json = """
        {
          "five_hour": { "resets_at": "2026-04-11T07:00:00Z" },
          "seven_day": { "utilization": 35.0 }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UsageResponse.self, from: json)
        XCTAssertNil(decoded.fiveHour, "missing utilization must not become 0%")
        XCTAssertEqual(decoded.sevenDay?.utilization, 35)
        XCTAssertTrue(decoded.hasDisplayableWindows)
    }

    func testEmptyUsageWindowsNotDisplayable() throws {
        let json = #"{"five_hour":null,"seven_day":null}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(UsageResponse.self, from: json)
        XCTAssertFalse(decoded.hasDisplayableWindows)
    }

    func testPlanEligibility() {
        XCTAssertEqual(PlanEligibility.from(subscriptionType: "pro"), .eligible)
        XCTAssertEqual(PlanEligibility.from(subscriptionType: "max"), .eligible)
        XCTAssertEqual(PlanEligibility.from(subscriptionType: "team"), .eligible)
        XCTAssertEqual(PlanEligibility.from(subscriptionType: "free"), .unsupported)
        XCTAssertEqual(PlanEligibility.from(subscriptionType: nil), .unknown)
    }

    func testParseCredentialsUnsupportedPlan() {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "credential-free",
            "subscriptionType": "free",
            "expiresAt": 4102444800000
          }
        }
        """
        let result = KeychainTokenReader.parseCredentialsJSON(json)
        guard case .failure(.unsupportedPlan) = result else {
            return XCTFail("expected unsupportedPlan, got \(result)")
        }
        XCTAssertEqual(KeychainTokenReader.authStatus(from: result), .unsupportedPlan)
    }

    func testParseCredentialsExpired() {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "credential-old",
            "expiresAt": 1000
          }
        }
        """
        let result = KeychainTokenReader.parseCredentialsJSON(json)
        guard case .failure(.expired) = result else {
            return XCTFail("expected expired, got \(result)")
        }
    }

    func testParseCredentialsZeroExpiresAtNotTreatedAsExpired() {
        // Missing/zero expiry must not surface as "token expired" — let the API decide.
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "credential-no-expiry",
            "expiresAt": 0
          }
        }
        """
        let result = KeychainTokenReader.parseCredentialsJSON(json)
        guard case .success(let token) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertNil(token.expiresAt)
    }

    func testParseCredentialsMissingExpiresAtSucceeds() {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "credential-live",
            "refreshToken": "ignored-live"
          }
        }
        """
        let result = KeychainTokenReader.parseCredentialsJSON(json)
        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
    }

    func testAuthStatusMappingIsDistinct() {
        XCTAssertEqual(
            KeychainTokenReader.authStatus(from: .failure(.itemNotFound)),
            .credentialsMissing
        )
        XCTAssertEqual(
            KeychainTokenReader.authStatus(from: .failure(.keychainDenied(status: errSecAuthFailed))),
            .keychainDenied(status: errSecAuthFailed)
        )
        // Claude Code expired ≠ this app's session ended (first-run must say Get started).
        XCTAssertEqual(
            KeychainTokenReader.authStatus(from: .failure(.expired)),
            .credentialsExpired
        )
        XCTAssertEqual(
            KeychainTokenReader.authStatus(from: .failure(.missingOAuth)),
            .apiKeyOnly
        )
        XCTAssertEqual(
            KeychainTokenReader.authStatus(from: .failure(.unsupportedPlan)),
            .unsupportedPlan
        )
        XCTAssertEqual(
            KeychainTokenReader.authStatus(from: .failure(.securityFailed(status: 1))),
            .keychainError(status: 1)
        )
        XCTAssertEqual(
            KeychainTokenReader.authStatus(from: .failure(.keychainDenied(status: errSecUserCanceled))),
            .keychainDenied(status: errSecUserCanceled)
        )
    }

    func testMissingCredentialsRequireClaudeCodeSignIn() {
        let missingResults: [Result<KeychainTokenReader.TokenResult, KeychainTokenReader.ReadError>] = [
            .failure(.itemNotFound),
            .failure(.emptyPassword),
        ]
        for result in missingResults {
            let status = KeychainTokenReader.authStatus(from: result)
            XCTAssertEqual(status, .credentialsMissing)
        }
        XCTAssertEqual(
            KeychainTokenReader.authStatus(from: .failure(.expired)),
            .credentialsExpired
        )

        XCTAssertEqual(
            TokenProvider.authStatus(from: .failure(.missingCredentials)),
            .credentialsMissing
        )
        XCTAssertEqual(
            TokenProvider.authStatus(from: .failure(.expiredCredentials)),
            .credentialsExpired
        )
        XCTAssertEqual(
            TokenProvider.authStatus(from: .failure(.notConnected)),
            .disconnected
        )
        XCTAssertEqual(
            TokenProvider.authStatus(from: .failure(.keychainFailed(status: 1))),
            .keychainError(status: 1)
        )
    }

    func testSetupCopyNeverSaysTokenExpired() {
        let statuses: [AuthStatus] = [
            .disconnected,
            .signInRequired,
            .credentialsMissing,
            .credentialsExpired,
            .keychainDenied(status: errSecAuthFailed),
            .keychainError(status: -1),
            .apiKeyOnly,
            .unsupportedPlan,
            .unknown,
            .parseError,
        ]
        for status in statuses {
            let title = status.setupTitle.lowercased()
            let message = status.setupMessage.lowercased()
            XCTAssertFalse(title.contains("token expired"), "title for \(status)")
            XCTAssertFalse(message.contains("token expired"), "message for \(status)")
            XCTAssertFalse(title.contains("session expired"), "title for \(status) must not say session expired")
            XCTAssertFalse(title.contains("oauth"), "title for \(status)")
        }
        XCTAssertEqual(AuthStatus.disconnected.setupTitle, "Connect Claude Code")
        XCTAssertEqual(AuthStatus.signInRequired.setupTitle, "Complete Claude Code sign-in")
        XCTAssertEqual(
            AuthStatus.keychainDenied(status: errSecAuthFailed).setupTitle,
            "Allow Keychain access"
        )
        XCTAssertEqual(AuthStatus.unsupportedPlan.setupTitle, "Plan doesn't include usage bars")
        XCTAssertTrue(AuthStatus.disconnected.showsConnectionButton)
        XCTAssertFalse(AuthStatus.signInRequired.showsConnectionButton)
        XCTAssertFalse(AuthStatus.unsupportedPlan.showsConnectionButton)
    }

    func testProductionKeychainStatusMappingPreservesFailures() {
        XCTAssertEqual(
            KeychainTokenReader.result(status: errSecItemNotFound, passwordData: nil),
            .failure(.itemNotFound)
        )
        XCTAssertEqual(
            KeychainTokenReader.result(status: errSecAuthFailed, passwordData: nil),
            .failure(.keychainDenied(status: errSecAuthFailed))
        )
        XCTAssertEqual(
            KeychainTokenReader.result(status: -9999, passwordData: nil),
            .failure(.securityFailed(status: -9999))
        )
    }

    func testParseCredentialsMissingOAuth() {
        let json = #"{"apiKey":"api-key-fixture"}"#
        let result = KeychainTokenReader.parseCredentialsJSON(json)
        guard case .failure(.missingOAuth) = result else {
            return XCTFail("expected missingOAuth, got \(result)")
        }
    }

    func testAllowlistedURL() {
        let good = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        XCTAssertTrue(UsageClient.isAllowlisted(good))
        XCTAssertFalse(UsageClient.isAllowlisted(URL(string: "https://evil.example/api/oauth/usage")!))
        XCTAssertFalse(UsageClient.isAllowlisted(URL(string: "http://api.anthropic.com/api/oauth/usage")!))
        XCTAssertFalse(UsageClient.isAllowlisted(URL(string: "https://api.anthropic.com/v1/messages")!))
    }

    func testColorBands() {
        XCTAssertEqual(UsageColorBand.band(forPeakUtilization: 0), .green)
        XCTAssertEqual(UsageColorBand.band(forPeakUtilization: 49.9), .green)
        XCTAssertEqual(UsageColorBand.band(forPeakUtilization: 50), .yellow)
        XCTAssertEqual(UsageColorBand.band(forPeakUtilization: 74.9), .yellow)
        XCTAssertEqual(UsageColorBand.band(forPeakUtilization: 75), .red)
        XCTAssertEqual(UsageColorBand.band(forPeakUtilization: 100), .red)
    }
}
