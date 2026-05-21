import Cocoa

class OverlayManager {
    private var windows: [OverlayWindow] = []
    private var watcher: WindowWatcher?
    private var updateWorkItem: DispatchWorkItem?
    private var lastActiveRect: CGRect?

    var isEnabled: Bool = true {
        didSet { updateOverlays() }
    }

    var dimmingAlpha: CGFloat = 0.55 {
        didSet { updateOverlays() }
    }

    var dimAdditionalDisplays: Bool = true {
        didSet { updateOverlays() }
    }

    var animationDuration: Double = 0.12 {
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
            lastActiveRect = nil
            windows.forEach { $0.hideMask(duration: animationDuration) }
            return
        }

        let currentRect = watcher?.activeWindowRect
        let hadRect = lastActiveRect != nil && !(lastActiveRect?.isEmpty ?? true)
        let hasRect = currentRect != nil && !(currentRect?.isEmpty ?? true)
        lastActiveRect = currentRect

        if immediate || hadRect == hasRect {
            // Continuous change (window moving/resizing) or stable state — update immediately
            updateWorkItem?.cancel()
            performUpdateOverlays(immediate: immediate)
        } else {
            // Window appeared or disappeared — debounce to avoid flicker from rapid nil↔rect switching.
            // 0.05s aligns with the poll interval so at most one transient switch is merged.
            updateWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.performUpdateOverlays()
            }
            updateWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
    }

    private func performUpdateOverlays(immediate: Bool = false) {
        guard isEnabled else {
            windows.forEach { $0.hideMask(duration: animationDuration) }
            return
        }

        guard var activeRect = watcher?.activeWindowRect, !activeRect.isEmpty else {
            // No active window (e.g. minimized, back to desktop) — clear all masks quickly
            windows.forEach { $0.hideMask(duration: immediate ? 0 : min(animationDuration, 0.06)) }
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
            if !intersection.isNull && intersection.width > minVisible && intersection.height > minVisible {
                var local = intersection
                local.origin.x -= windowFrame.origin.x
                local.origin.y -= windowFrame.origin.y
                window.showMask(holeRect: local, alpha: dimmingAlpha, duration: animationDuration, cornerRadius: radius)
            } else if dimAdditionalDisplays {
                window.showMask(holeRect: nil, alpha: dimmingAlpha, duration: animationDuration, cornerRadius: radius)
            } else {
                window.hideMask(duration: animationDuration)
            }
        }
    }
}
