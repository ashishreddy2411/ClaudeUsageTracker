import Foundation
import ServiceManagement

enum LaunchAtLoginRegistrationStatus: Equatable {
    case enabled
    case requiresApproval
    case disabled
}

protocol LaunchAtLoginControlling {
    func registrationStatus() -> LaunchAtLoginRegistrationStatus
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginController: LaunchAtLoginControlling {
    func registrationStatus() -> LaunchAtLoginRegistrationStatus {
        let status = SMAppService.mainApp.status
        if status == .enabled {
            return .enabled
        }
        if status == .requiresApproval {
            return .requiresApproval
        }
        return .disabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if registrationStatus() != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if registrationStatus() != .disabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

enum NotificationWindowKind: String, CaseIterable, Codable, Sendable {
    case session
    case weekly
}

/// Which usage window drives the menu bar percentage and ring.
///
/// `.peak` preserves the historical behavior (the larger of session and weekly), so
/// existing installs see no change until the user picks otherwise. The raw values are
/// persisted in UserDefaults and must stay stable.
enum MenuPercentSource: String, CaseIterable, Codable, Sendable {
    case peak
    case session
    case weekly

    var displayName: String {
        switch self {
        case .peak: return "Highest (Session or Weekly)"
        case .session: return "Session"
        case .weekly: return "Weekly"
        }
    }

    var accessibilityName: String {
        switch self {
        case .peak: return "Claude usage"
        case .session: return "Claude session usage"
        case .weekly: return "Claude weekly usage"
        }
    }
}

/// UserDefaults-backed settings. Never stores tokens.
@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    private let defaults: UserDefaults
    private let launchAtLoginController: any LaunchAtLoginControlling

    private enum Key {
        static let notificationsEnabled = "notificationsEnabled"
        static let thresholds = "enabledThresholds"
        static let refreshMinutes = "refreshIntervalMinutes"
        static let showPercentInMenu = "showPercentInMenu"
        static let menuPercentSource = "menuPercentSource"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let legacyFiredThresholds = "firedThresholdsByWindow"
        static let firedWindowRecords = "firedWindowRecordsV2"
        static let firedWindowSequence = "firedWindowRecencySequence"
        static let localWindowStates = "localNotificationWindowStates"
        static let launchAtLogin = "launchAtLogin"
        /// Explicit, persisted consent to read Claude Code's Keychain item.
        static let claudeCodeConnectionEnabled = "claudeCodeConnectionEnabled"
        static let notificationsDenied = "notificationsAuthorizationDenied"
    }

    /// Default thresholds: 25, 50, 75, 90.
    static let allThresholds: [Int] = [25, 50, 75, 90]
    static let nilResetRolloverTolerance = 10.0
    private static let retainedWindowsPerKind = 8

    private struct FiredWindowRecord: Codable {
        var thresholds: [Int]
        var lastSeenSequence: Int
    }

    private struct LocalWindowState: Codable {
        var generation: Int
        var peakUtilization: Double
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    @Published var enabledThresholds: Set<Int> {
        didSet { defaults.set(Array(enabledThresholds).sorted(), forKey: Key.thresholds) }
    }

    /// 5 or 10 minutes.
    @Published var refreshIntervalMinutes: Int {
        didSet {
            let clamped = refreshIntervalMinutes <= 5 ? 5 : 10
            if clamped != refreshIntervalMinutes {
                refreshIntervalMinutes = clamped
                return
            }
            defaults.set(clamped, forKey: Key.refreshMinutes)
        }
    }

    @Published var showPercentInMenu: Bool {
        didSet { defaults.set(showPercentInMenu, forKey: Key.showPercentInMenu) }
    }

    /// Which window the menu bar reports. Defaults to `.peak`.
    @Published var menuPercentSource: MenuPercentSource {
        didSet { defaults.set(menuPercentSource.rawValue, forKey: Key.menuPercentSource) }
    }

    @Published var hasCompletedFirstRun: Bool {
        didSet { defaults.set(hasCompletedFirstRun, forKey: Key.hasCompletedFirstRun) }
    }

    /// Off by default. Credential reads are forbidden unless this is true.
    @Published var claudeCodeConnectionEnabled: Bool {
        didSet { defaults.set(claudeCodeConnectionEnabled, forKey: Key.claudeCodeConnectionEnabled) }
    }

    /// User denied notification permission — Settings can surface this instead of silent no-op (L3).
    @Published var notificationsAuthorizationDenied: Bool {
        didSet { defaults.set(notificationsAuthorizationDenied, forKey: Key.notificationsDenied) }
    }

    /// Carbon key code for `U` is 32; cmd is `cmdKey` (8).
    @Published var hotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(hotkeyKeyCode), forKey: Key.hotkeyKeyCode) }
    }

    @Published var hotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(hotkeyModifiers), forKey: Key.hotkeyModifiers) }
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    var refreshInterval: TimeInterval {
        TimeInterval(refreshIntervalMinutes * 60)
    }

    init(
        defaults: UserDefaults = .standard,
        launchAtLoginController: any LaunchAtLoginControlling = SystemLaunchAtLoginController()
    ) {
        self.defaults = defaults
        self.launchAtLoginController = launchAtLoginController

        // Alerts OFF by default (new installs). Existing keys are honored, then
        // reconciled against UNAuthorizationStatus on launch / Settings appear.
        if defaults.object(forKey: Key.notificationsEnabled) == nil {
            defaults.set(false, forKey: Key.notificationsEnabled)
        }
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)

        if let stored = defaults.array(forKey: Key.thresholds) as? [Int], !stored.isEmpty {
            enabledThresholds = Set(stored)
        } else {
            enabledThresholds = Set(Self.allThresholds)
        }

        let minutes = defaults.integer(forKey: Key.refreshMinutes)
        refreshIntervalMinutes = (minutes == 10) ? 10 : 5

        showPercentInMenu = defaults.bool(forKey: Key.showPercentInMenu)
        // Unknown or absent raw values fall back to the historical peak behavior.
        menuPercentSource = defaults.string(forKey: Key.menuPercentSource)
            .flatMap(MenuPercentSource.init(rawValue:)) ?? .peak
        hasCompletedFirstRun = defaults.bool(forKey: Key.hasCompletedFirstRun)
        claudeCodeConnectionEnabled = defaults.bool(forKey: Key.claudeCodeConnectionEnabled)
        notificationsAuthorizationDenied = defaults.bool(forKey: Key.notificationsDenied)

        let keyCode = defaults.integer(forKey: Key.hotkeyKeyCode)
        hotkeyKeyCode = keyCode > 0 ? UInt32(keyCode) : 32 // kVK_ANSI_U
        let mods = defaults.integer(forKey: Key.hotkeyModifiers)
        hotkeyModifiers = mods > 0 ? UInt32(mods) : UInt32(cmdKey)

        let requestedLaunchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        launchAtLogin = false
        launchAtLoginError = nil
        reconcileLaunchAtLogin(requestedEnable: requestedLaunchAtLogin)
    }

    func toggleThreshold(_ value: Int) {
        var next = enabledThresholds
        if next.contains(value) {
            next.remove(value)
        } else {
            next.insert(value)
        }
        enabledThresholds = next
    }

    // MARK: - Notification de-dupe persistence

    /// Returns a stable key for a server reset time, or a persisted local generation
    /// when the API omits `resetsAt`. A meaningful utilization rollover advances only
    /// that kind's generation; small reporting fluctuations do not rearm alerts.
    func notificationWindowKey(
        kind: NotificationWindowKind,
        resetsAt: Date?,
        utilization: Double
    ) -> String {
        if let resetsAt {
            return "\(kind.rawValue)|\(Int(resetsAt.timeIntervalSince1970))"
        }

        var states = loadLocalWindowStates()
        let currentUtilization = min(max(utilization, 0), 100)
        var state = states[kind.rawValue] ?? LocalWindowState(
            generation: 0,
            peakUtilization: currentUtilization
        )
        if state.peakUtilization - currentUtilization >= Self.nilResetRolloverTolerance {
            state.generation += 1
            state.peakUtilization = currentUtilization
        } else {
            state.peakUtilization = max(state.peakUtilization, currentUtilization)
        }
        states[kind.rawValue] = state
        saveLocalWindowStates(states)
        return "\(kind.rawValue)|local|\(state.generation)"
    }

    func firedThresholds(forWindowKey key: String) -> Set<Int> {
        var records = loadFiredWindowRecords()
        var record = records[key] ?? FiredWindowRecord(thresholds: [], lastSeenSequence: 0)
        record.lastSeenSequence = nextFiredWindowSequence()
        records[key] = record
        pruneFiredWindowRecords(&records, preserving: key)
        saveFiredWindowRecords(records)
        return Set(record.thresholds)
    }

    func markThresholdFired(_ threshold: Int, windowKey: String) {
        var records = loadFiredWindowRecords()
        var record = records[windowKey] ?? FiredWindowRecord(
            thresholds: [],
            lastSeenSequence: 0
        )
        var set = Set(record.thresholds)
        set.insert(threshold)
        record.thresholds = Array(set).sorted()
        record.lastSeenSequence = nextFiredWindowSequence()
        records[windowKey] = record
        pruneFiredWindowRecords(&records, preserving: windowKey)
        saveFiredWindowRecords(records)
    }

    func clearFiredThresholds() {
        defaults.removeObject(forKey: Key.legacyFiredThresholds)
        defaults.removeObject(forKey: Key.firedWindowRecords)
        defaults.removeObject(forKey: Key.firedWindowSequence)
        defaults.removeObject(forKey: Key.localWindowStates)
    }

    private func loadFiredWindowRecords() -> [String: FiredWindowRecord] {
        if let data = defaults.data(forKey: Key.firedWindowRecords),
           let records = try? JSONDecoder().decode([String: FiredWindowRecord].self, from: data) {
            defaults.removeObject(forKey: Key.legacyFiredThresholds)
            return records
        }

        defaults.removeObject(forKey: Key.firedWindowRecords)
        guard let legacy = defaults.dictionary(forKey: Key.legacyFiredThresholds) else {
            return [:]
        }

        var records: [String: FiredWindowRecord] = [:]
        for oldKey in legacy.keys.sorted(by: legacyWindowOrder) {
            guard let kind = notificationWindowKind(forKey: oldKey),
                  let thresholds = legacy[oldKey] as? [Int] else {
                continue
            }
            let normalizedKey = oldKey == "\(kind.rawValue)|0"
                ? "\(kind.rawValue)|local|0"
                : oldKey
            var merged = Set(records[normalizedKey]?.thresholds ?? [])
            merged.formUnion(thresholds)
            records[normalizedKey] = FiredWindowRecord(
                thresholds: Array(merged).sorted(),
                lastSeenSequence: nextFiredWindowSequence()
            )
        }
        pruneFiredWindowRecords(&records, preserving: nil)
        saveFiredWindowRecords(records)
        defaults.removeObject(forKey: Key.legacyFiredThresholds)
        return records
    }

    private func saveFiredWindowRecords(_ records: [String: FiredWindowRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Key.firedWindowRecords)
    }

    private func pruneFiredWindowRecords(
        _ records: inout [String: FiredWindowRecord],
        preserving currentKey: String?
    ) {
        records = records.filter { notificationWindowKind(forKey: $0.key) != nil }
        for kind in NotificationWindowKind.allCases {
            let keys = records.keys.filter {
                notificationWindowKind(forKey: $0) == kind
            }
            let excess = keys.count - Self.retainedWindowsPerKind
            guard excess > 0 else { continue }
            let removable = keys
                .filter { $0 != currentKey }
                .sorted {
                    let lhs = records[$0]?.lastSeenSequence ?? 0
                    let rhs = records[$1]?.lastSeenSequence ?? 0
                    return lhs == rhs ? $0 < $1 : lhs < rhs
                }
            for staleKey in removable.prefix(excess) {
                records.removeValue(forKey: staleKey)
            }
        }
    }

    private func nextFiredWindowSequence() -> Int {
        let next = defaults.integer(forKey: Key.firedWindowSequence) + 1
        defaults.set(next, forKey: Key.firedWindowSequence)
        return next
    }

    private func notificationWindowKind(forKey key: String) -> NotificationWindowKind? {
        guard let rawKind = key.split(separator: "|", maxSplits: 1).first else {
            return nil
        }
        return NotificationWindowKind(rawValue: String(rawKind))
    }

    private func legacyWindowOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsEpoch = Int(lhs.split(separator: "|").last ?? "") ?? 0
        let rhsEpoch = Int(rhs.split(separator: "|").last ?? "") ?? 0
        return lhsEpoch == rhsEpoch ? lhs < rhs : lhsEpoch < rhsEpoch
    }

    private func loadLocalWindowStates() -> [String: LocalWindowState] {
        guard let data = defaults.data(forKey: Key.localWindowStates),
              let states = try? JSONDecoder().decode([String: LocalWindowState].self, from: data) else {
            return [:]
        }
        return states
    }

    private func saveLocalWindowStates(_ states: [String: LocalWindowState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: Key.localWindowStates)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            try launchAtLoginController.setEnabled(enabled)
            reconcileLaunchAtLogin(requestedEnable: enabled)
        } catch {
            reconcileLaunchAtLogin(requestedEnable: enabled)
            launchAtLoginError = enabled
                ? "Launch at Login could not be enabled."
                : "Launch at Login could not be disabled."
        }
    }

    func reconcileLaunchAtLogin() {
        reconcileLaunchAtLogin(requestedEnable: nil)
    }

    private func reconcileLaunchAtLogin(requestedEnable: Bool?) {
        switch launchAtLoginController.registrationStatus() {
        case .enabled:
            launchAtLogin = true
            launchAtLoginError = nil
        case .requiresApproval:
            launchAtLogin = false
            if requestedEnable == true {
                launchAtLoginError = "Allow ClaudeUsageBar in System Settings → General → Login Items."
            }
        case .disabled:
            launchAtLogin = false
            if requestedEnable == true {
                launchAtLoginError = "Launch at Login was not enabled."
            }
        }
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
    }
}

// Carbon cmdKey constant without importing Carbon in this file's API surface.
private let cmdKey: Int = 256
