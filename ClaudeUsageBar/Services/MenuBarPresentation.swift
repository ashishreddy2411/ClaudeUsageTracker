import AppKit

/// Keeps the system menu bar visible while our MenuBarExtra UI is open over fullscreen apps.
///
/// ## Apple guidance (why this exists)
/// - Status items live in the **system** menu bar and must remain usable while other apps
///   are frontmost (`About Status Bars` / Cocoa Status Bar conceptual docs). Menu bar
///   extras that present UI over a fullscreen Space must not yank the user out of that Space.
/// - `NSApplication.presentationOptions` apply while *this* app is active
///   (`NSApplication.presentationOptions`). Do **not** set `.hideMenuBar` / `.autoHideMenuBar`
///   (those require matching Dock-hide flags and would hide the bar that hosts the status item).
///   Empty / default options keep the menu bar visible — required while our extra is presented.
/// - Host windows for the extra must use `NSWindow.CollectionBehavior.fullScreenAuxiliary`
///   so they participate in another app’s fullscreen Space (WWDC 2015 “Improving the Full
///   Screen Window Experience”; AppKit `CollectionBehavior` docs). Pair with
///   `.moveToActiveSpace` so ordering front joins the active Space (do **not** also set
///   `.canJoinAllSpaces` — AppKit asserts those two are mutually exclusive).
/// - Stay `LSUIElement` / `.accessory` — no Dock icon.
///
/// ## Known OS quirk
/// Activating an accessory over a fullscreen Space can briefly re-hide the menu bar
/// (FB13544993). We re-assert `presentationOptions = []` on become-active and after
/// short deferred passes while the UI is open.
///
/// ## Verify (fullscreen Safari)
/// 1. Build & launch ClaudeUsageBar (menu-bar spark only — no Dock icon).
/// 2. Open Safari → green button → enter **fullscreen** (separate Space).
/// 3. Move the pointer to the top of the screen so the menu bar peeks; click the spark
///    **or** press **⌘U**.
/// 4. Expected: ClaudeUsageBar panel appears **in the Safari fullscreen Space**, and the
///    **system menu bar stays visible** for the whole time the panel is open (status items
///    remain reachable). Dismiss (click outside / ⌘U again) → menu bar may auto-hide again
///    as Safari’s fullscreen presentation resumes.
@MainActor
enum MenuBarPresentation {
    private static var savedPresentationOptions: NSApplication.PresentationOptions?
    private(set) static var isHoldingMenuBarVisible = false
    private static var reassertTimer: Timer?

    /// How often to re-assert while the panel is open.
    ///
    /// The previous implementation re-asserted three times (0s, 0.05s, 0.2s) and then
    /// stopped. A fullscreen host re-applies its own auto-hide presentation whenever
    /// the pointer leaves the menu bar, which is usually well after 0.2s, so the bar
    /// slid away with the panel still open. Re-asserting for as long as the panel is
    /// held is what actually covers pointer movement.
    static let reassertInterval: TimeInterval = 0.25
    private static var didInstallObservers = false
    private static var observerTokens: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    /// Call once at launch (AppDelegate). Wires observers so click-open and ⌘U both stay covered.
    static func install() {
        guard !didInstallObservers else { return }
        didInstallObservers = true

        let center = NotificationCenter.default
        let queue = OperationQueue.main

        observerTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: queue
        ) { _ in
            Task { @MainActor in
                guard isHoldingMenuBarVisible else { return }
                assertMenuBarVisible()
                configureMenuBarWindows()
                // AppKit may re-apply fullscreen presentation after activation (FB13544993).
                reassertAfterActivationSettles()
            }
        })

        observerTokens.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: queue
        ) { note in
            Task { @MainActor in
                guard let window = note.object as? NSWindow, isMenuBarHosted(window) else { return }
                beginMenuBarUI()
            }
        })

        observerTokens.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: queue
        ) { note in
            Task { @MainActor in
                guard let window = note.object as? NSWindow, isMenuBarHosted(window) else { return }
                // Defer: resign-key often fires during focus moves inside the panel.
                DispatchQueue.main.async {
                    syncHoldToVisibleHostWindows()
                }
            }
        })

        // Catch MenuBarExtra panels that order on-screen without becoming key first.
        observerTokens.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: queue
        ) { note in
            Task { @MainActor in
                guard let window = note.object as? NSWindow, isMenuBarHosted(window) else { return }
                if window.occlusionState.contains(.visible), window.isVisible {
                    beginMenuBarUI()
                } else {
                    DispatchQueue.main.async {
                        syncHoldToVisibleHostWindows()
                    }
                }
            }
        })
    }

    /// Call when the MenuBarExtra UI is shown (popover appear / ⌘U open / host window key).
    /// Idempotent — safe to call from multiple open paths without nested hold counts.
    static func beginMenuBarUI() {
        if !isHoldingMenuBarVisible {
            isHoldingMenuBarVisible = true
            savedPresentationOptions = NSApp.presentationOptions
        }
        assertMenuBarVisible()
        configureMenuBarWindows()
        reassertAfterActivationSettles()
        startReassertTimer()
    }

    /// Presentation options only take effect for the *active* application, so an
    /// inactive accessory cannot keep another app's fullscreen menu bar revealed.
    /// Re-activating while the panel is open is what makes our options authoritative.
    private static func startReassertTimer() {
        reassertTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: reassertInterval,
            repeats: true
        ) { _ in
            Task { @MainActor in
                guard isHoldingMenuBarVisible else {
                    stopReassertTimer()
                    return
                }
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
                assertMenuBarVisible()
                configureMenuBarWindows()
            }
        }
        // .common so the re-assert keeps firing during menu tracking and scrolling.
        RunLoop.main.add(timer, forMode: .common)
        reassertTimer = timer
    }

    private static func stopReassertTimer() {
        reassertTimer?.invalidate()
        reassertTimer = nil
    }

    /// Call when the MenuBarExtra UI is dismissed.
    /// Idempotent — only restores when we were actually holding.
    static func endMenuBarUI() {
        guard isHoldingMenuBarVisible else { return }
        isHoldingMenuBarVisible = false
        stopReassertTimer()
        if let saved = savedPresentationOptions {
            // Never re-apply hide-menu-bar flags from a previous session.
            let hidesMenuBar = saved.contains(.hideMenuBar) || saved.contains(.autoHideMenuBar)
            NSApp.presentationOptions = hidesMenuBar ? [] : saved
        } else {
            NSApp.presentationOptions = []
        }
        savedPresentationOptions = nil
    }

    /// Align hold state with whether any MenuBarExtra / status host window is on-screen.
    static func syncHoldToVisibleHostWindows() {
        let anyVisible = NSApp.windows.contains { isMenuBarHosted($0) && $0.isVisible }
        if anyVisible {
            beginMenuBarUI()
        } else {
            endMenuBarUI()
        }
    }

    // MARK: - Presentation options

    /// Force options that keep the system menu bar visible while we are active.
    static func assertMenuBarVisible() {
        // Default (empty) presentation: menu bar follows normal system behavior while we
        // are active. Never allow hideMenuBar / autoHideMenuBar for this accessory.
        NSApp.presentationOptions = []
    }

    private static func reassertAfterActivationSettles() {
        DispatchQueue.main.async {
            guard isHoldingMenuBarVisible else { return }
            assertMenuBarVisible()
            configureMenuBarWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard isHoldingMenuBarVisible else { return }
            assertMenuBarVisible()
            configureMenuBarWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard isHoldingMenuBarVisible else { return }
            assertMenuBarVisible()
            configureMenuBarWindows()
        }
    }

    // MARK: - Window collection behavior

    /// Configure every MenuBarExtra / status-bar hosted window for fullscreen Spaces.
    static func configureMenuBarWindows() {
        for window in NSApp.windows where isMenuBarHosted(window) {
            configure(window)
        }
    }

    static func configure(_ window: NSWindow) {
        window.collectionBehavior = collectionBehavior(
            from: window.collectionBehavior
        )

        // Stay above the fullscreen app's content without capturing the display.
        if window.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
            window.level = .popUpMenu
        }

        if let panel = window as? NSPanel {
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
        }
    }

    /// Pure collection-behavior policy, separated from NSWindow mutation so the
    /// mutually-exclusive Spaces flags are regression-testable without UI hosting.
    static func collectionBehavior(
        from existing: NSWindow.CollectionBehavior
    ) -> NSWindow.CollectionBehavior {
        var behavior = existing
        // Must not be a fullscreen *primary* window — that fights auxiliary presentation.
        behavior.remove(.fullScreenPrimary)
        behavior.remove(.fullScreenNone)
        // canJoinAllSpaces and moveToActiveSpace are mutually exclusive (AppKit assertion).
        // Clear any inherited canJoinAllSpaces before setting moveToActiveSpace.
        behavior.remove(.canJoinAllSpaces)
        // Join the active fullscreen Space instead of switching to Desktop 1.
        // fullScreenAuxiliary is required to show in another app's fullscreen Space.
        behavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
        return behavior
    }

    static func isMenuBarHosted(_ window: NSWindow) -> Bool {
        let name = String(describing: type(of: window))
        // SwiftUI MenuBarExtra .window content host (not the thin NSStatusBar strip).
        if name.contains("MenuBarExtra") {
            return true
        }
        // Presented panel: tall enough to be the popover, at status/pop-up level.
        // Exclude the persistent status-item chrome (typically ~height of the menu bar).
        guard window.frame.height > 80, window.contentView != nil else { return false }
        if window is NSPanel {
            return window.level.rawValue >= NSWindow.Level.floating.rawValue
        }
        return window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
    }
}
