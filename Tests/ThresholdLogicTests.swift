import AppKit
import UserNotifications
import XCTest
@testable import ClaudeUsageBar

@MainActor
final class ThresholdLogicTests: XCTestCase {
    func testNotificationsDisabledByDefault() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertFalse(store.notificationsAuthorizationDenied)
        XCTAssertEqual(store.enabledThresholds, Set(PreferencesStore.allThresholds))
    }

    func testPermissionReconcileRules() {
        let denied = NotificationService.reconcile(
            preferenceEnabled: true,
            status: .denied
        )
        XCTAssertFalse(denied.enabled)
        XCTAssertTrue(denied.deniedHint)

        let undetermined = NotificationService.reconcile(
            preferenceEnabled: true,
            status: .notDetermined
        )
        XCTAssertFalse(undetermined.enabled)
        XCTAssertFalse(undetermined.deniedHint)

        let authorized = NotificationService.reconcile(
            preferenceEnabled: true,
            status: .authorized
        )
        XCTAssertTrue(authorized.enabled)
        XCTAssertFalse(authorized.deniedHint)

        let offButAuthorized = NotificationService.reconcile(
            preferenceEnabled: false,
            status: .authorized
        )
        XCTAssertFalse(offButAuthorized.enabled)
    }

    func testPermissionSufficientStatuses() {
        XCTAssertTrue(NotificationService.isPermissionSufficient(.authorized))
        XCTAssertTrue(NotificationService.isPermissionSufficient(.provisional))
        XCTAssertFalse(NotificationService.isPermissionSufficient(.denied))
        XCTAssertFalse(NotificationService.isPermissionSufficient(.notDetermined))
    }

    func testEnableAlertsDeniedForcesOff() async {
        let (store, _) = makeStore()
        let service = NotificationService(
            deliveryProvider: ImmediateNotificationProvider(status: .denied)
        )

        service.enableAlerts(preferences: store)
        await service.waitForPermissionOperationsForTesting()

        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertTrue(store.notificationsAuthorizationDenied)
    }

    func testEnableAlertsAuthorizedKeepsOn() async {
        let (store, _) = makeStore()
        let service = NotificationService(
            deliveryProvider: ImmediateNotificationProvider(status: .authorized)
        )

        service.enableAlerts(preferences: store)
        await service.waitForPermissionOperationsForTesting()

        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertFalse(store.notificationsAuthorizationDenied)
    }

    func testEnableAlertsNotDeterminedUsesRequestResult() async {
        let (grantedStore, _) = makeStore()
        let grantedService = NotificationService(
            deliveryProvider: ImmediateNotificationProvider(
                status: .notDetermined,
                requestResult: true
            )
        )
        grantedService.enableAlerts(preferences: grantedStore)
        await grantedService.waitForPermissionOperationsForTesting()
        XCTAssertTrue(grantedStore.notificationsEnabled)
        XCTAssertFalse(grantedStore.notificationsAuthorizationDenied)

        let (deniedStore, _) = makeStore()
        let deniedService = NotificationService(
            deliveryProvider: ImmediateNotificationProvider(
                status: .notDetermined,
                requestResult: false
            )
        )
        deniedService.enableAlerts(preferences: deniedStore)
        await deniedService.waitForPermissionOperationsForTesting()
        XCTAssertFalse(deniedStore.notificationsEnabled)
        XCTAssertTrue(deniedStore.notificationsAuthorizationDenied)
    }

    func testDelayedPermissionStatusCannotReenableAfterToggleOff() async {
        let (store, _) = makeStore()
        let provider = DelayedStatusNotificationProvider()
        let service = NotificationService(deliveryProvider: provider)

        service.enableAlerts(preferences: store)
        await provider.waitUntilStatusRequested()
        service.disableAlerts(preferences: store)
        await provider.resumeStatus(.authorized)
        await service.waitForPermissionOperationsForTesting()

        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertFalse(store.notificationsAuthorizationDenied)
    }

    func testDelayedPermissionGrantCannotReenableAfterToggleOff() async {
        let (store, _) = makeStore()
        let provider = DelayedRequestNotificationProvider()
        let service = NotificationService(deliveryProvider: provider)

        service.enableAlerts(preferences: store)
        await provider.waitUntilRequestStarted()
        service.disableAlerts(preferences: store)
        await provider.resumeRequest(granted: true)
        await service.waitForPermissionOperationsForTesting()

        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertFalse(store.notificationsAuthorizationDenied)
    }

    func testReconcileWithSystemPermissionFlipsStaleOn() async {
        let (store, _) = makeStore()
        store.notificationsEnabled = true
        let service = NotificationService(
            deliveryProvider: ImmediateNotificationProvider(status: .denied)
        )

        service.reconcileWithSystemPermission(preferences: store)
        await service.waitForPermissionOperationsForTesting()

        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertTrue(store.notificationsAuthorizationDenied)
    }

    func testThresholdSelection() {
        XCTAssertEqual(
            NotificationService.thresholdsToFire(
                utilization: 55,
                enabled: Set([25, 50, 75, 90]),
                alreadyFired: []
            ),
            [25, 50]
        )
        XCTAssertEqual(
            NotificationService.thresholdsToFire(
                utilization: 80,
                enabled: Set([25, 50, 75, 90]),
                alreadyFired: [25, 50]
            ),
            [75]
        )
        XCTAssertEqual(
            NotificationService.thresholdsToFire(
                utilization: 95,
                enabled: Set([90]),
                alreadyFired: []
            ),
            [90]
        )
        XCTAssertTrue(
            NotificationService.thresholdsToFire(
                utilization: 10,
                enabled: Set([25, 50, 75, 90]),
                alreadyFired: []
            ).isEmpty
        )
    }

    func testWindowKeysEncodeResetOrLocalGeneration() {
        let session = NotificationService.windowKey(
            kind: "session",
            resetsAt: Date(timeIntervalSince1970: 1_000)
        )
        let next = NotificationService.windowKey(
            kind: "session",
            resetsAt: Date(timeIntervalSince1970: 2_000)
        )
        let weekly = NotificationService.windowKey(
            kind: "weekly",
            resetsAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(session, "session|1000")
        XCTAssertNotEqual(session, next)
        XCTAssertNotEqual(session, weekly)
        XCTAssertEqual(
            NotificationService.windowKey(
                kind: "session",
                resetsAt: nil,
                localGeneration: 3
            ),
            "session|local|3"
        )
    }

    func testPreferencesPersistFiredThresholds() {
        let (store, _) = makeStore()
        let key = NotificationService.windowKey(
            kind: "session",
            resetsAt: Date(timeIntervalSince1970: 42)
        )
        XCTAssertTrue(store.firedThresholds(forWindowKey: key).isEmpty)
        store.markThresholdFired(25, windowKey: key)
        store.markThresholdFired(50, windowKey: key)
        XCTAssertEqual(store.firedThresholds(forWindowKey: key), Set([25, 50]))
    }

    func testLegacyFiredDictionaryMigratesAndCleansUp() {
        let (store, defaults) = makeStore()
        defaults.set(["session|0": [25, 50]], forKey: "firedThresholdsByWindow")

        let localKey = store.notificationWindowKey(
            kind: .session,
            resetsAt: nil,
            utilization: 55
        )

        XCTAssertEqual(localKey, "session|local|0")
        XCTAssertEqual(store.firedThresholds(forWindowKey: localKey), Set([25, 50]))
        XCTAssertNil(defaults.object(forKey: "firedThresholdsByWindow"))
    }

    func testWeeklyPruningCannotEvictActiveSessionWindow() async {
        let (store, _) = makeStore()
        store.notificationsEnabled = true
        store.enabledThresholds = [50]
        let sessionReset = Date(timeIntervalSince1970: 10_000)
        let sessionKey = NotificationService.windowKey(
            kind: "session",
            resetsAt: sessionReset
        )
        store.markThresholdFired(50, windowKey: sessionKey)

        for index in 0..<12 {
            let weeklyKey = NotificationService.windowKey(
                kind: "weekly",
                resetsAt: Date(timeIntervalSince1970: TimeInterval(20_000 + index))
            )
            store.markThresholdFired(25, windowKey: weeklyKey)
        }

        let provider = ImmediateNotificationProvider(status: .authorized)
        let service = NotificationService(deliveryProvider: provider)
        service.evaluate(
            usage: UsageResponse(
                fiveHour: UsageWindow(utilization: 55, resetsAt: sessionReset)
            ),
            preferences: store
        )
        await service.waitForPendingDeliveriesForTesting()

        let deliveryCount = await provider.deliveryCount()
        XCTAssertEqual(store.firedThresholds(forWindowKey: sessionKey), Set([50]))
        XCTAssertEqual(deliveryCount, 0)
    }

    func testNilResetGenerationsRearmAcrossMultipleRollovers() async {
        let (store, _) = makeStore()
        store.notificationsEnabled = true
        store.enabledThresholds = [50]
        let provider = ImmediateNotificationProvider(status: .authorized)
        let service = NotificationService(deliveryProvider: provider)

        await evaluateNilReset(55, service: service, store: store)
        await evaluateNilReset(51, service: service, store: store)
        await evaluateNilReset(5, service: service, store: store)
        await evaluateNilReset(55, service: service, store: store)
        await evaluateNilReset(48, service: service, store: store)
        await evaluateNilReset(1, service: service, store: store)
        await evaluateNilReset(55, service: service, store: store)

        let deliveryCount = await provider.deliveryCount()
        XCTAssertEqual(deliveryCount, 3)
    }

    func testFailedDeliveryDoesNotConsumeThreshold() async {
        let (store, _) = makeStore()
        store.notificationsEnabled = true
        store.enabledThresholds = [50]
        let resetsAt = Date(timeIntervalSince1970: 42)
        let key = NotificationService.windowKey(kind: "session", resetsAt: resetsAt)
        let usage = UsageResponse(
            fiveHour: UsageWindow(utilization: 55, resetsAt: resetsAt)
        )
        let provider = ImmediateNotificationProvider(
            status: .authorized,
            deliveryResult: false
        )
        let service = NotificationService(deliveryProvider: provider)

        service.evaluate(usage: usage, preferences: store)
        await service.waitForPendingDeliveriesForTesting()
        XCTAssertTrue(store.firedThresholds(forWindowKey: key).isEmpty)

        await provider.setDeliveryResult(true)
        service.evaluate(usage: usage, preferences: store)
        await service.waitForPendingDeliveriesForTesting()
        XCTAssertEqual(store.firedThresholds(forWindowKey: key), Set([50]))
    }

    func testOffMainDeliveryCallbackMarksFiredOnProductionServicePath() async {
        let (store, _) = makeStore()
        store.notificationsEnabled = true
        store.enabledThresholds = [50]
        let resetsAt = Date(timeIntervalSince1970: 314)
        let key = NotificationService.windowKey(kind: "session", resetsAt: resetsAt)
        let provider = BackgroundNotificationProvider()
        let service = NotificationService(deliveryProvider: provider)

        service.evaluate(
            usage: UsageResponse(
                fiveHour: UsageWindow(utilization: 55, resetsAt: resetsAt)
            ),
            preferences: store
        )
        await service.waitForPendingDeliveriesForTesting()

        XCTAssertEqual(store.firedThresholds(forWindowKey: key), Set([50]))
        XCTAssertEqual(provider.callbackWasOnMainThread, false)
    }

    func testMenuBarCollectionBehaviorNeverCombinesExclusiveSpaceFlags() {
        let original: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenPrimary,
            .fullScreenNone,
        ]

        let result = MenuBarPresentation.collectionBehavior(from: original)

        XCTAssertFalse(result.contains(.canJoinAllSpaces))
        XCTAssertTrue(result.contains(.moveToActiveSpace))
        XCTAssertTrue(result.contains(.fullScreenAuxiliary))
        XCTAssertFalse(
            result.contains(.canJoinAllSpaces) && result.contains(.moveToActiveSpace)
        )
    }

    func testFormatRemaining() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            UsageBarRow.formatRemaining(
                until: now.addingTimeInterval(90 * 60),
                now: now
            ),
            "1h 30m"
        )
        XCTAssertEqual(
            UsageBarRow.formatRemaining(
                until: now.addingTimeInterval(10 * 60),
                now: now
            ),
            "10m"
        )
        XCTAssertEqual(
            UsageBarRow.formatRemaining(
                until: now.addingTimeInterval(3 * 24 * 3600 + 2 * 3600),
                now: now
            ),
            "3d 2h"
        )
    }

    private func makeStore() -> (PreferencesStore, UserDefaults) {
        let suiteName = "ClaudeUsageBar.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (PreferencesStore(defaults: defaults), defaults)
    }

    private func evaluateNilReset(
        _ utilization: Double,
        service: NotificationService,
        store: PreferencesStore
    ) async {
        service.evaluate(
            usage: UsageResponse(
                fiveHour: UsageWindow(utilization: utilization, resetsAt: nil)
            ),
            preferences: store
        )
        await service.waitForPendingDeliveriesForTesting()
    }
}

private actor ImmediateNotificationProvider: NotificationDeliveryProviding {
    private let status: UNAuthorizationStatus
    private let requestResult: Bool
    private var deliveryResult: Bool
    private var deliveries = 0

    init(
        status: UNAuthorizationStatus,
        requestResult: Bool = false,
        deliveryResult: Bool = true
    ) {
        self.status = status
        self.requestResult = requestResult
        self.deliveryResult = deliveryResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> Bool {
        requestResult
    }

    func deliver(_ request: UNNotificationRequest) async -> Bool {
        deliveries += 1
        return deliveryResult
    }

    func setDeliveryResult(_ result: Bool) {
        deliveryResult = result
    }

    func deliveryCount() -> Int {
        deliveries
    }
}

private actor DelayedStatusNotificationProvider: NotificationDeliveryProviding {
    private var continuation: CheckedContinuation<UNAuthorizationStatus, Never>?

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ request: UNNotificationRequest) async -> Bool {
        true
    }

    func waitUntilStatusRequested() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resumeStatus(_ status: UNAuthorizationStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}

private actor DelayedRequestNotificationProvider: NotificationDeliveryProviding {
    private var continuation: CheckedContinuation<Bool, Never>?

    func authorizationStatus() async -> UNAuthorizationStatus {
        .notDetermined
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func deliver(_ request: UNNotificationRequest) async -> Bool {
        true
    }

    func waitUntilRequestStarted() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resumeRequest(granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

private final class BackgroundNotificationProvider: NotificationDeliveryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var callbackMainThreadValue: Bool?

    var callbackWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return callbackMainThreadValue
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        .authorized
    }

    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ request: UNNotificationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.lock.lock()
                self.callbackMainThreadValue = Thread.isMainThread
                self.lock.unlock()
                continuation.resume(returning: true)
            }
        }
    }
}
