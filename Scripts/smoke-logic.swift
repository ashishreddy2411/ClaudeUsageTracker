#!/usr/bin/env swift
import Foundation

// Lightweight smoke test for decoding + threshold logic (no Xcode required).

struct UsageResponse: Codable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
    var peakUtilization: Double {
        max(fiveHour?.utilization ?? 0, sevenDay?.utilization ?? 0)
    }
}

struct UsageWindow: Codable {
    var utilization: Double
    var resetsAt: Date?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Never invent 0% — require Anthropic's field.
        utilization = try c.decode(Double.self, forKey: .utilization)
        if let raw = try c.decodeIfPresent(String.self, forKey: .resetsAt) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = f.date(from: raw) ?? {
                let s = ISO8601DateFormatter()
                s.formatOptions = [.withInternetDateTime]
                return s.date(from: raw)
            }()
        }
    }
}

func band(_ p: Double) -> String {
    if p < 50 { return "green" }
    if p < 75 { return "yellow" }
    return "red"
}

func thresholdsToFire(utilization: Double, enabled: Set<Int>, alreadyFired: Set<Int>) -> [Int] {
    [25, 50, 75, 90]
        .filter { enabled.contains($0) }
        .filter { utilization >= Double($0) }
        .filter { !alreadyFired.contains($0) }
}

let json = """
{"five_hour":{"utilization":33.0,"resets_at":"2026-04-11T07:00:00.528743+00:00"},"seven_day":{"utilization":80.0,"resets_at":"2026-04-17T00:59:59Z"}}
""".data(using: .utf8)!

let decoded = try JSONDecoder().decode(UsageResponse.self, from: json)
assert(decoded.fiveHour?.utilization == 33)
assert(decoded.sevenDay?.utilization == 80)
assert(decoded.peakUtilization == 80)
assert(band(decoded.peakUtilization) == "red")
assert(thresholdsToFire(utilization: 55, enabled: [25, 50, 75, 90], alreadyFired: []) == [25, 50])
assert(thresholdsToFire(utilization: 80, enabled: [25, 50, 75, 90], alreadyFired: [25, 50]) == [75])
assert(band(49.9) == "green" && band(50) == "yellow" && band(75) == "red")

let allow = URL(string: "https://api.anthropic.com/api/oauth/usage")!
assert(allow.host == "api.anthropic.com" && allow.path == "/api/oauth/usage" && allow.scheme == "https")

// Connection copy must stay actionable and honest about Claude Code.
struct AuthCopySmoke {
    static func title(for kind: String) -> String {
        switch kind {
        case "disconnected": return "Connect Claude Code"
        case "signIn": return "Complete Claude Code sign-in"
        case "denied": return "Allow Keychain access"
        case "plan": return "Plan doesn't include usage bars"
        default: return "Connect Claude Code"
        }
    }
}
assert(AuthCopySmoke.title(for: "disconnected") == "Connect Claude Code")
assert(AuthCopySmoke.title(for: "signIn") == "Complete Claude Code sign-in")
assert(AuthCopySmoke.title(for: "plan") == "Plan doesn't include usage bars")
assert(!AuthCopySmoke.title(for: "signIn").lowercased().contains("token"))

// expiresAt <= 0 must not be treated as epoch-1970 expiry.
func expirationDate(expiresAt: Double?) -> Date? {
    guard let expiresAt, expiresAt > 0 else { return nil }
    if expiresAt > 1_000_000_000_000 {
        return Date(timeIntervalSince1970: expiresAt / 1000)
    }
    return Date(timeIntervalSince1970: expiresAt)
}
assert(expirationDate(expiresAt: 0) == nil)
assert(expirationDate(expiresAt: nil) == nil)
assert(expirationDate(expiresAt: 4102444800000) != nil)

func planEligible(_ raw: String?) -> String {
    guard let raw = raw?.lowercased(), !raw.isEmpty else { return "unknown" }
    if ["free", "none", "api"].contains(raw) { return "unsupported" }
    if ["pro", "max", "team", "enterprise"].contains(where: { raw.contains($0) }) { return "eligible" }
    return "unknown"
}
assert(planEligible("pro") == "eligible")
assert(planEligible("free") == "unsupported")
assert(planEligible(nil) == "unknown")

let officialSetup = URL(string: "https://code.claude.com/docs/en/quickstart#step-2-log-in-to-your-account")!
assert(officialSetup.scheme == "https" && officialSetup.host == "code.claude.com")

print("OK: decode, color bands, threshold dedupe, allowlist shape, connection copy, expiry edge cases, plan eligibility, external setup link")
