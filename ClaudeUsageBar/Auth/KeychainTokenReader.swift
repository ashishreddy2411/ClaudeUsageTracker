import Foundation
import Security

/// Reads Claude Code's macOS Keychain item after the user explicitly connects.
/// Never writes Keychain entries or `~/.claude/.credentials.json`.
enum KeychainTokenReader {
    static let serviceName = "Claude Code-credentials"
    private static let readQueue = DispatchQueue(
        label: "com.claudeusagebar.keychain-read",
        qos: .userInitiated
    )

    enum ReadError: Error, Equatable, Sendable {
        case securityFailed(status: OSStatus)
        case itemNotFound
        case keychainDenied(status: OSStatus)
        case emptyPassword
        case decodeFailed
        case missingOAuth
        case unsupportedPlan
        case expired
    }

    struct TokenResult: Equatable, Sendable {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
    }

    static func readAccessToken() async -> Result<TokenResult, ReadError> {
        await withCheckedContinuation { continuation in
            readQueue.async {
                var item: CFTypeRef?
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: serviceName,
                    kSecMatchLimit: kSecMatchLimitOne,
                    kSecReturnData: true,
                ]
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                continuation.resume(
                    returning: result(
                        status: status,
                        passwordData: item as? Data
                    )
                )
            }
        }
    }

    static func result(
        status: OSStatus,
        passwordData: Data?
    ) -> Result<TokenResult, ReadError> {
        guard status == 0 else {
            if status == errSecItemNotFound {
                return .failure(.itemNotFound)
            }
            if isKeychainDenied(status: status) {
                return .failure(.keychainDenied(status: status))
            }
            return .failure(.securityFailed(status: status))
        }

        guard let passwordData,
              var json = String(data: passwordData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !json.isEmpty else {
            return .failure(.emptyPassword)
        }

        // Tolerate legacy entries whose JSON was stored with wrapping quotes.
        if json.hasPrefix("\""), json.hasSuffix("\""), json.count > 1 {
            json = String(json.dropFirst().dropLast())
        }

        return parseCredentialsJSON(json)
    }

    static func parseCredentialsJSON(_ json: String) -> Result<TokenResult, ReadError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(.decodeFailed)
        }

        let decoder = JSONDecoder()
        do {
            let blob = try decoder.decode(ClaudeCredentialsBlob.self, from: data)
            guard let oauth = blob.claudeAiOauth else {
                return .failure(.missingOAuth)
            }
            guard !oauth.accessToken.isEmpty else {
                return .failure(.missingOAuth)
            }
            if oauth.isExpired {
                return .failure(.expired)
            }
            // Free / API-labeled subscriptions never get session+weekly bars.
            if PlanEligibility.from(subscriptionType: oauth.subscriptionType) == .unsupported {
                return .failure(.unsupportedPlan)
            }
            return .success(
                TokenResult(
                    accessToken: oauth.accessToken,
                    expiresAt: oauth.expirationDate,
                    subscriptionType: oauth.subscriptionType
                )
            )
        } catch {
            return .failure(.decodeFailed)
        }
    }

    static func authStatus(from result: Result<TokenResult, ReadError>) -> AuthStatus {
        switch result {
        case .success:
            return .ready(source: .claudeCode)
        case .failure(.itemNotFound), .failure(.emptyPassword):
            return .credentialsMissing
        case .failure(.missingOAuth):
            return .apiKeyOnly
        case .failure(.unsupportedPlan):
            return .unsupportedPlan
        case .failure(.expired):
            return .credentialsExpired
        case .failure(.keychainDenied(let status)):
            return .keychainDenied(status: status)
        case .failure(.securityFailed(let status)):
            return .keychainError(status: status)
        case .failure(.decodeFailed):
            return .parseError
        }
    }

    static func isKeychainDenied(status: OSStatus) -> Bool {
        status == errSecUserCanceled
            || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
    }
}
