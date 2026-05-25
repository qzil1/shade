import Cocoa

enum OverlayDefaults {
    static let isEnabled = true
    static let slowAnimationDuration = 0.3
    static let fastAnimationDuration = 0.02
    static let mediumAnimationDuration = 1.0 / ((1.0 / slowAnimationDuration + 1.0 / fastAnimationDuration) / 2.0)
}

class OverlayManager {
    private var windows: [OverlayWindow] = []
    private var watcher: WindowWatcher?
    private var updateWorkItem: DispatchWorkItem?
    private var transitionWorkItem: DispatchWorkItem?
    private var lastActiveRect: CGRect?

    var isEnabled: Bool = OverlayDefaults.isEnabled {
        didSet { updateOverlays() }
    }

    var dimmingAlpha: CGFloat = 0.55 {
        didSet { updateOverlays() }
    }

    var dimAdditionalDisplays: Bool = true {
        didSet { updateOverlays() }
    }

    var animationDuration: Double = OverlayDefaults.mediumAnimationDuration {
        didSet { updateOverlays() }
    }

    func start() {
        createWindows()

        watcher = WindowWatcher()
        watcher?.onChange = { [weak self] immediate in
            self?.updateOverlays(immediate: immediate)
        }
        watcher?.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        createWindows()
        updateOverlays()
    }

    private func createWindows() {
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { screen in
            let w = OverlayWindow(screen: screen)
            w.orderFront()
            return w
        }
    }

    private func updateOverlays(immediate: Bool = false) {
        guard isEnabled else {
            updateWorkItem?.cancel()
            transitionWorkItem?.cancel()
            lastActiveRect = nil
            windows.forEach { $0.hideMask(duration: animationDuration) }
            return
        }

        let currentRect = watcher?.activeWindowRect
        let hadRect = lastActiveRect != nil && !(lastActiveRect?.isEmpty ?? true)
        let hasRect = currentRect != nil && !(currentRect?.isEmpty ?? true)

        let isSwitch = hadRect && hasRect
            && lastActiveRect != nil && currentRect != nil
            && !lastActiveRect!.equalTo(currentRect!)

        lastActiveRect = currentRect

        if immediate || hadRect == hasRect {
            // Continuous change (window moving/resizing) or stable state — update immediately
            updateWorkItem?.cancel()
            transitionWorkItem?.cancel()

            if isSwitch && !immediate {
                // Transition: hole disappears (full mask), then new hole appears immediately.
                // Step 1: animate hole collapsing into full mask.
                performUpdateOverlays(forceHole: false)
                // Step 2: show new hole without path animation so it doesn't fly in from (-1,-1).
                let workItem = DispatchWorkItem { [weak self] in
                    self?.performUpdateOverlays(customDuration: 0)
                }
                transitionWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration, execute: workItem)
            } else {
                performUpdateOverlays(immediate: immediate)
            }
        } else {
            // Window appeared or disappeared — debounce to avoid flicker from rapid nil↔rect switching.
            // 0.05s aligns with the poll interval so at most one transient switch is merged.
            updateWorkItem?.cancel()
            transitionWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.performUpdateOverlays()
            }
            updateWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
    }

    private func performUpdateOverlays(immediate: Bool = false, forceHole: Bool = true, customDuration: Double? = nil) {
        let duration = customDuration ?? animationDuration

        guard isEnabled else {
            windows.forEach { $0.hideMask(duration: duration) }
            return
        }

        guard var activeRect = watcher?.activeWindowRect, !activeRect.isEmpty else {
            // No active window (e.g. minimized, back to desktop) — clear all masks quickly
            windows.forEach { $0.hideMask(duration: immediate ? 0 : min(duration, 0.06)) }
            return
        }

        // Accessibility API returns coordinates with top-left origin (Y down),
        // but NSScreen.frame / NSWindow.frame use bottom-left origin (Y up).
        // The AX origin is fixed to the primary display (menu bar), so we must
        // use CGMainDisplayID() instead of NSScreen.main which changes with
        // the key window.
        let primaryID = CGMainDisplayID()
        let primaryScreen = NSScreen.screens.first { screen in
            let sid = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return sid == primaryID
        }
        let primaryFrame = primaryScreen?.frame ?? NSScreen.main?.frame ?? .zero
        activeRect.origin.y = primaryFrame.minY + primaryFrame.height - activeRect.origin.y - activeRect.height

        let radius: CGFloat
        if let bundleID = watcher?.frontAppBundleID, bundleID.hasPrefix("com.apple.") {
            radius = 24
        } else {
            radius = 14
        }

        for window in windows {
            let screenFrame = window.targetScreen.frame
            let windowFrame = window.window.frame
            let intersection = activeRect.intersection(screenFrame)

            // Only show a hole if the window meaningfully overlaps this screen.
            // A tiny sliver (e.g. 19 px) at a screen edge looks like a glitch.
            let minVisible: CGFloat = 40
            let shouldShowHole = !intersection.isNull
                && intersection.width > minVisible
                && intersection.height > minVisible

            if shouldShowHole && forceHole {
                var local = intersection
                local.origin.x -= windowFrame.origin.x
                local.origin.y -= windowFrame.origin.y
                window.showMask(holeRect: local, alpha: dimmingAlpha, duration: duration, cornerRadius: radius)
            } else if !forceHole || dimAdditionalDisplays {
                // Transition mode: always show full mask (no hole).
                // Normal mode: show full mask on non-active displays when enabled.
                window.showMask(holeRect: nil, alpha: dimmingAlpha, duration: duration, cornerRadius: radius)
            } else {
                window.hideMask(duration: duration)
            }
        }
    }
}
