import Cocoa

class WindowWatcher {
    var onChange: ((_ immediate: Bool) -> Void)?
    private(set) var activeWindowRect: CGRect?

    private var timer: Timer?
    private var lastFrontApp: NSRunningApplication?
    private(set) var frontAppBundleID: String?
    private var axObserver: AXObserver?
    private var activeWindow: AXUIElement?
    private var lastStableActiveWindow: AXUIElement?
    private var lastStableActiveWindowRect: CGRect?
    private var lastStableFrontAppBundleID: String?
    private var preserveStableActiveWindowUntil: Date?
    private var mouseDownMonitor: Any?
    private var pendingAppChangePoll: DispatchWorkItem?

    // Require 2 consecutive AX failures before treating as "no active window".
    // This filters out transient errors during minimize animations.
    private var nilStreak: Int = 0
    private let nilThreshold: Int = 2

    // After detecting minimization, ignore rect recoveries for 0.4s to avoid
    // flicker caused by unstable AX data during the minimize animation.
    private var minimizationGracePeriod: Date?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.poll()
        }

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if Thread.isMainThread {
                self?.handleMouseDown(event)
            } else {
                DispatchQueue.main.async {
                    self?.handleMouseDown(event)
                }
            }
        }

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            setupAXObserver(for: frontApp)
        }
    }

    deinit {
        timer?.invalidate()
        pendingAppChangePoll?.cancel()
        if let mouseDownMonitor = mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
        }
        removeAXObserver()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - AXObserver

    private func removeAXObserver() {
        guard let observer = axObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = nil
    }

    private func setupAXObserver(for app: NSRunningApplication) {
        removeAXObserver()

        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }

        let pid = pid_t(app.processIdentifier)
        var newObserver: AXObserver?

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let notificationName = notification as String
            DispatchQueue.main.async {
                watcher.handleAXNotification(notificationName, element: element)
            }
        }

        guard AXObserverCreate(pid, callback, &newObserver) == .success, let observer = newObserver else {
            return
        }

        let axApp = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(observer, axApp, "AXFocusedWindowChanged" as CFString, selfPtr)
        AXObserverAddNotification(observer, axApp, "AXWindowMiniaturized" as CFString, selfPtr)
        AXObserverAddNotification(observer, axApp, "AXWindowDeminiaturized" as CFString, selfPtr)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    private func handleAXNotification(_ notification: String, element: AXUIElement) {
        if notification == "AXWindowMiniaturized" {
            if isCurrentOrStableWindow(element) {
                clearActiveWindow(immediate: true)
                return
            }

            preserveStableActiveWindow()
            return
        }

        poll()
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard activeWindowRect != nil || lastStableActiveWindowRect != nil,
              let cgEvent = event.cgEvent else {
            return
        }

        guard let hitElement = elementAtScreenPosition(cgEvent.location),
              let minimizeButton = minimizeButtonElement(from: hitElement),
              let containingWindow = containingWindow(of: minimizeButton) else {
            return
        }

        if isCurrentOrStableWindow(containingWindow) {
            clearActiveWindow(immediate: true)
        } else {
            preserveStableActiveWindow()
        }
    }

    private func elementAtScreenPosition(_ position: CGPoint) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWideElement, Float(position.x), Float(position.y), &element)
        return result == .success ? element : nil
    }

    private func minimizeButtonElement(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element

        for _ in 0..<8 {
            guard let candidate = current else { return nil }

            if stringAttribute(kAXSubroleAttribute as CFString, of: candidate) == "AXMinimizeButton" {
                return candidate
            }

            current = elementAttribute(kAXParentAttribute as CFString, of: candidate)
        }

        return nil
    }

    private func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element

        for _ in 0..<12 {
            guard let candidate = current else { return nil }

            if stringAttribute(kAXRoleAttribute as CFString, of: candidate) == "AXWindow" {
                return candidate
            }

            current = elementAttribute(kAXParentAttribute as CFString, of: candidate)
        }

        return nil
    }

    private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func isCurrentOrStableWindow(_ window: AXUIElement) -> Bool {
        if let activeWindow = activeWindow, CFEqual(window, activeWindow) {
            return true
        }

        if let lastStableActiveWindow = lastStableActiveWindow, CFEqual(window, lastStableActiveWindow) {
            return true
        }

        return false
    }

    private func clearActiveWindow(immediate: Bool) {
        nilStreak = 0
        activeWindowRect = nil
        activeWindow = nil
        lastStableActiveWindow = nil
        lastStableActiveWindowRect = nil
        lastStableFrontAppBundleID = nil
        preserveStableActiveWindowUntil = nil
        minimizationGracePeriod = Date().addingTimeInterval(0.4)
        onChange?(immediate)
    }

    private func recordStableActiveWindow(_ window: AXUIElement, rect: CGRect) {
        activeWindow = window
        lastStableActiveWindow = window
        lastStableActiveWindowRect = rect
        lastStableFrontAppBundleID = frontAppBundleID
    }

    private func preserveStableActiveWindow() {
        guard let stableRect = lastStableActiveWindowRect else { return }

        preserveStableActiveWindowUntil = Date().addingTimeInterval(0.6)

        if let lastStableActiveWindow = lastStableActiveWindow {
            activeWindow = lastStableActiveWindow
        }
        frontAppBundleID = lastStableFrontAppBundleID

        if activeWindowRect == nil || !stableRect.equalTo(activeWindowRect!) {
            activeWindowRect = stableRect
            onChange?(false)
        }
    }

    private func keepStableActiveWindowIfNeeded() -> Bool {
        guard let until = preserveStableActiveWindowUntil else { return false }

        if Date() >= until {
            preserveStableActiveWindowUntil = nil
            return false
        }

        guard let stableRect = lastStableActiveWindowRect else {
            return false
        }

        nilStreak = 0
        if let lastStableActiveWindow = lastStableActiveWindow {
            activeWindow = lastStableActiveWindow
        }
        frontAppBundleID = lastStableFrontAppBundleID

        if activeWindowRect == nil || !stableRect.equalTo(activeWindowRect!) {
            activeWindowRect = stableRect
            onChange?(false)
        }

        return true
    }

    @objc private func appChanged() {
        nilStreak = 0
        minimizationGracePeriod = nil
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            setupAXObserver(for: frontApp)
        }

        // Give the mouse-down hit test for the same click a chance to mark
        // non-active minimize before app activation polling rewrites stability.
        pendingAppChangePoll?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.poll()
        }
        pendingAppChangePoll = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
    }

    // MARK: - Polling

    private func poll() {
        guard AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        ) else {
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        if frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }

        if keepStableActiveWindowIfNeeded() {
            return
        }

        lastFrontApp = frontApp
        frontAppBundleID = frontApp.bundleIdentifier

        let axApp = AXUIElementCreateApplication(pid_t(frontApp.processIdentifier))
        var value: AnyObject?

        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)

        guard result == .success, let axWindow = value else {
            nilStreak += 1
            if nilStreak >= nilThreshold && activeWindowRect != nil {
                activeWindowRect = nil
                activeWindow = nil
                lastStableActiveWindow = nil
                lastStableActiveWindowRect = nil
                lastStableFrontAppBundleID = nil
                preserveStableActiveWindowUntil = nil
                minimizationGracePeriod = nil
                onChange?(false)
            }
            return
        }
        nilStreak = 0
        let focusedWindow = axWindow as! AXUIElement

        // Check minimized first: if true, skip reading position/size entirely.
        var minimizedValue: AnyObject?
        let minimizedResult = AXUIElementCopyAttributeValue(focusedWindow, "AXMinimized" as CFString, &minimizedValue)
        if minimizedResult == .success,
           let minimized = minimizedValue as? NSNumber,
           minimized.boolValue {
            if activeWindowRect != nil {
                activeWindowRect = nil
                activeWindow = nil
                lastStableActiveWindow = nil
                lastStableActiveWindowRect = nil
                lastStableFrontAppBundleID = nil
                preserveStableActiveWindowUntil = nil
                minimizationGracePeriod = Date().addingTimeInterval(0.4)
                onChange?(false)
            }
            return
        }

        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        let posResult = AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValue)

        guard posResult == .success, sizeResult == .success,
              let posAX = positionValue, let sizeAX = sizeValue else {
            if activeWindowRect != nil {
                activeWindowRect = nil
                activeWindow = nil
                lastStableActiveWindow = nil
                lastStableActiveWindowRect = nil
                lastStableFrontAppBundleID = nil
                preserveStableActiveWindowUntil = nil
                onChange?(false)
            }
            return
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        let gotPos = AXValueGetValue(posAX as! AXValue, .cgPoint, &position)
        let gotSize = AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)

        guard gotPos, gotSize else {
            if activeWindowRect != nil {
                activeWindowRect = nil
                activeWindow = nil
                lastStableActiveWindow = nil
                lastStableActiveWindowRect = nil
                lastStableFrontAppBundleID = nil
                preserveStableActiveWindowUntil = nil
                onChange?(false)
            }
            return
        }

        let newRect = CGRect(origin: position, size: size)

        // Detect minimization by sudden rect collapse during animation.
        // When a window minimizes, its AX-reported rect shrinks dramatically.
        if let lastRect = activeWindowRect,
           !lastRect.isEmpty,
           newRect.width * newRect.height < lastRect.width * lastRect.height * 0.15 {
            activeWindowRect = nil
            activeWindow = nil
            lastStableActiveWindow = nil
            lastStableActiveWindowRect = nil
            lastStableFrontAppBundleID = nil
            preserveStableActiveWindowUntil = nil
            minimizationGracePeriod = Date().addingTimeInterval(0.4)
            onChange?(false)
            return
        }

        // Grace period: after detecting minimization, ignore any rect "recoveries"
        // caused by unstable AX data during the animation.
        if let until = minimizationGracePeriod, Date() < until {
            return
        }
        minimizationGracePeriod = nil
        preserveStableActiveWindowUntil = nil
        recordStableActiveWindow(focusedWindow, rect: newRect)

        if activeWindowRect == nil || !newRect.equalTo(activeWindowRect!) {
            activeWindowRect = newRect
            onChange?(false)
        }
    }
}
