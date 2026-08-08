import AppKit
import Foundation
import UserNotifications

protocol NotificationDeliveryProviding: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func deliver(_ request: UNNotificationRequest) async -> Bool
}

/// Bridges callbacks from UserNotifications without exposing their executor to
/// main-actor preference state.
final class SystemNotificationDeliveryProvider: NotificationDeliveryProviding, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        let status = await authorizationStatus()
        return NotificationService.isPermissionSufficient(status) || granted
    }

    func deliver(_ request: UNNotificationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}

/// Fires threshold notifications once per level per rolling usage window.
/// Alerts stay OFF until the user opts in *and* system authorization is sufficient.
/// Delivery and fired-state persistence run serially on the main actor.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private struct DeliveryID: Hashable {
        let preferences: ObjectIdentifier
        let windowKey: String
        let threshold: Int
    }

    private struct QueuedDelivery {
        let id: DeliveryID
        let title: String
        let body: String
        let preferences: PreferencesStore
    }

    private let deliveryProvider: any NotificationDeliveryProviding
    private var pendingDeliveryIDs: Set<DeliveryID> = []
    private var deliveryQueue: [QueuedDelivery] = []
    private var deliveryWorker: Task<Void, Never>?
    private var permissionOperationGeneration: UInt64 = 0
    private var desiredAlertsEnabled = false
    private var activePermissionOperations = 0

    init(
        deliveryProvider: any NotificationDeliveryProviding = SystemNotificationDeliveryProvider()
    ) {
        self.deliveryProvider = deliveryProvider
        super.init()
    }

    // MARK: - Pure helpers

    nonisolated static func isPermissionSufficient(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated static func reconcile(
        preferenceEnabled: Bool,
        status: UNAuthorizationStatus
    ) -> (enabled: Bool, deniedHint: Bool) {
        switch status {
        case .authorized, .provisional:
            return (preferenceEnabled, false)
        case .denied:
            return (false, true)
        case .notDetermined:
            return (false, false)
        @unknown default:
            return (false, false)
        }
    }

    nonisolated static func thresholdsToFire(
        utilization: Double,
        enabled: Set<Int>,
        alreadyFired: Set<Int>
    ) -> [Int] {
        [25, 50, 75, 90]
            .filter { enabled.contains($0) }
            .filter { utilization >= Double($0) }
            .filter { !alreadyFired.contains($0) }
            .sorted()
    }

    nonisolated static func windowKey(
        kind: String,
        resetsAt: Date?,
        localGeneration: Int = 0
    ) -> String {
        if let resetsAt {
            return "\(kind)|\(Int(resetsAt.timeIntervalSince1970))"
        }
        return "\(kind)|local|\(localGeneration)"
    }

    // MARK: - Evaluate / deliver

    func evaluate(usage: UsageResponse, preferences: PreferencesStore) {
        guard preferences.notificationsEnabled else { return }

        evaluateWindow(
            kind: .session,
            window: usage.fiveHour,
            preferences: preferences
        )
        evaluateWindow(
            kind: .weekly,
            window: usage.sevenDay,
            preferences: preferences
        )
    }

    /// Sync preferences with current system permission. A user operation started
    /// after this check invalidates its result.
    func reconcileWithSystemPermission(preferences: PreferencesStore) {
        let generation = permissionOperationGeneration
        activePermissionOperations += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activePermissionOperations -= 1 }
            let status = await self.deliveryProvider.authorizationStatus()
            guard generation == self.permissionOperationGeneration else { return }
            let result = Self.reconcile(
                preferenceEnabled: preferences.notificationsEnabled,
                status: status
            )
            preferences.notificationsEnabled = result.enabled
            preferences.notificationsAuthorizationDenied = result.deniedHint
        }
    }

    /// Records the latest user intent before any asynchronous permission work.
    /// A stale authorization response can therefore never undo a later OFF action.
    func setAlertsEnabled(_ wantsOn: Bool, preferences: PreferencesStore) {
        permissionOperationGeneration &+= 1
        let generation = permissionOperationGeneration
        desiredAlertsEnabled = wantsOn
        preferences.notificationsEnabled = wantsOn
        guard wantsOn else { return }

        activePermissionOperations += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activePermissionOperations -= 1 }
            await self.resolveEnableRequest(
                generation: generation,
                preferences: preferences
            )
        }
    }

    func enableAlerts(preferences: PreferencesStore) {
        setAlertsEnabled(true, preferences: preferences)
    }

    func disableAlerts(preferences: PreferencesStore) {
        setAlertsEnabled(false, preferences: preferences)
    }

    func openSystemNotificationSettings() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)",
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleId)",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func waitForPendingDeliveriesForTesting() async {
        while !pendingDeliveryIDs.isEmpty || deliveryWorker != nil {
            await Task.yield()
        }
    }

    func waitForPermissionOperationsForTesting() async {
        while activePermissionOperations > 0 {
            await Task.yield()
        }
    }

    // MARK: - Private

    private func resolveEnableRequest(
        generation: UInt64,
        preferences: PreferencesStore
    ) async {
        let status = await deliveryProvider.authorizationStatus()
        guard isLatestEnableRequest(generation, preferences: preferences) else { return }

        switch status {
        case .authorized, .provisional:
            preferences.notificationsAuthorizationDenied = false
            preferences.notificationsEnabled = true
        case .denied:
            preferences.notificationsEnabled = false
            preferences.notificationsAuthorizationDenied = true
        case .notDetermined:
            let granted = await deliveryProvider.requestAuthorization()
            guard isLatestEnableRequest(generation, preferences: preferences) else { return }
            preferences.notificationsEnabled = granted
            preferences.notificationsAuthorizationDenied = !granted
        @unknown default:
            preferences.notificationsEnabled = false
            preferences.notificationsAuthorizationDenied = false
        }
    }

    private func isLatestEnableRequest(
        _ generation: UInt64,
        preferences: PreferencesStore
    ) -> Bool {
        generation == permissionOperationGeneration
            && desiredAlertsEnabled
            && preferences.notificationsEnabled
    }

    private func evaluateWindow(
        kind: NotificationWindowKind,
        window: UsageWindow?,
        preferences: PreferencesStore
    ) {
        guard let window else { return }
        let key = preferences.notificationWindowKey(
            kind: kind,
            resetsAt: window.resetsAt,
            utilization: window.utilization
        )
        let fired = preferences.firedThresholds(forWindowKey: key)
        let toFire = Self.thresholdsToFire(
            utilization: window.utilization,
            enabled: preferences.enabledThresholds,
            alreadyFired: fired
        )

        for threshold in toFire {
            enqueueDelivery(
                kind: kind,
                utilization: window.utilization,
                threshold: threshold,
                windowKey: key,
                preferences: preferences
            )
        }
    }

    private func enqueueDelivery(
        kind: NotificationWindowKind,
        utilization: Double,
        threshold: Int,
        windowKey: String,
        preferences: PreferencesStore
    ) {
        let id = DeliveryID(
            preferences: ObjectIdentifier(preferences),
            windowKey: windowKey,
            threshold: threshold
        )
        guard pendingDeliveryIDs.insert(id).inserted else { return }

        deliveryQueue.append(
            QueuedDelivery(
                id: id,
                title: "Claude usage at \(threshold)%",
                body: kind == .session
                    ? "Session (5-hour) usage reached \(Int(utilization))%."
                    : "Weekly (7-day) usage reached \(Int(utilization))%.",
                preferences: preferences
            )
        )
        startDeliveryWorkerIfNeeded()
    }

    private func startDeliveryWorkerIfNeeded() {
        guard deliveryWorker == nil else { return }
        deliveryWorker = Task { @MainActor [weak self] in
            await self?.drainDeliveryQueue()
        }
    }

    private func drainDeliveryQueue() async {
        while !deliveryQueue.isEmpty {
            let item = deliveryQueue.removeFirst()
            let delivered = await deliver(
                title: item.title,
                body: item.body,
                preferences: item.preferences
            )
            if delivered {
                item.preferences.markThresholdFired(
                    item.id.threshold,
                    windowKey: item.id.windowKey
                )
            }
            pendingDeliveryIDs.remove(item.id)
        }
        deliveryWorker = nil
    }

    private func deliver(
        title: String,
        body: String,
        preferences: PreferencesStore
    ) async -> Bool {
        guard preferences.notificationsEnabled else { return false }
        let status = await deliveryProvider.authorizationStatus()
        guard preferences.notificationsEnabled else { return false }
        guard Self.isPermissionSufficient(status) else {
            if status == .denied {
                preferences.notificationsAuthorizationDenied = true
                preferences.notificationsEnabled = false
            }
            return false
        }

        preferences.notificationsAuthorizationDenied = false
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        return await deliveryProvider.deliver(request)
    }
}
