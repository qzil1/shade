import Cocoa

class WindowWatcher {
    var onChange: ((_ immediate: Bool) -> Void)?
    private(set) var activeWindowRect: CGRect?

    private var timer: Timer?
    private var lastFrontApp: NSRunningApplication?
    private(set) var frontAppBundleID: String?
    private var axObserver: AXObserver?
    private var activeWindow: AXUIElement?
    private var mouseEventTap: CFMachPort?
    private var mouseEventTapSource: CFRunLoopSource?
    private var protectedActiveWindow: AXUIElement?
    private var protectedActiveWindowRect: CGRect?
    private var protectedFrontAppBundleID: String?
    private var nonActiveMinimizeProtectionUntil: Date?

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

        setupMouseEventTap()

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            setupAXObserver(for: frontApp)
        }
    }

    deinit {
        timer?.invalidate()
        removeMouseEventTap()
        removeAXObserver()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Mouse Events

    private func setupMouseEventTap() {
        removeMouseEventTap()

        let eventMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }

            let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()

            if type == .leftMouseDown {
                let location = event.location
                DispatchQueue.main.async {
                    watcher.handleMouseDown(at: location)
                }
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async {
                    if let tap = watcher.mouseEventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }
            }

            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        mouseEventTap = tap
        mouseEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeMouseEventTap() {
        if let source = mouseEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = mouseEventTap {
            CFMachPortInvalidate(tap)
        }
        mouseEventTapSource = nil
        mouseEventTap = nil
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
        if notification == "AXWindowMiniaturized",
           let activeWindow = activeWindow,
           activeWindowRect != nil,
           CFEqual(element, activeWindow) {
            nilStreak = 0
            activeWindowRect = nil
            self.activeWindow = nil
            minimizationGracePeriod = Date().addingTimeInterval(0.4)
            onChange?(true)
            return
        }

        poll()
    }

    private func handleMouseDown(at position: CGPoint) {
        guard activeWindowRect != nil,
              let activeWindow = activeWindow else {
            return
        }

        guard let hitElement = elementAtScreenPosition(position),
              let minimizeButton = minimizeButtonElement(from: hitElement),
              let containingWindow = containingWindow(of: minimizeButton) else {
            return
        }

        if CFEqual(containingWindow, activeWindow) {
            clearActiveWindow(immediate: true)
        } else {
            protectActiveWindowFromNonActiveMinimize()
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

    private func clearActiveWindow(immediate: Bool) {
        nilStreak = 0
        activeWindowRect = nil
        activeWindow = nil
        clearNonActiveMinimizeProtection()
        minimizationGracePeriod = Date().addingTimeInterval(0.4)
        onChange?(immediate)
    }

    private func protectActiveWindowFromNonActiveMinimize() {
        guard let activeWindowRect = activeWindowRect else { return }

        protectedActiveWindow = activeWindow
        protectedActiveWindowRect = activeWindowRect
        protectedFrontAppBundleID = frontAppBundleID
        nonActiveMinimizeProtectionUntil = Date().addingTimeInterval(0.7)
    }

    private func clearNonActiveMinimizeProtection() {
        protectedActiveWindow = nil
        protectedActiveWindowRect = nil
        protectedFrontAppBundleID = nil
        nonActiveMinimizeProtectionUntil = nil
    }

    private func keepProtectedActiveWindowIfNeeded() -> Bool {
        guard let until = nonActiveMinimizeProtectionUntil else {
            return false
        }

        if Date() >= until {
            clearNonActiveMinimizeProtection()
            return false
        }

        guard let protectedRect = protectedActiveWindowRect else {
            clearNonActiveMinimizeProtection()
            return false
        }

        nilStreak = 0
        activeWindow = protectedActiveWindow
        frontAppBundleID = protectedFrontAppBundleID

        if activeWindowRect == nil || !protectedRect.equalTo(activeWindowRect!) {
            activeWindowRect = protectedRect
            onChange?(false)
        }

        return true
    }

    @objc private func appChanged() {
        nilStreak = 0
        minimizationGracePeriod = nil
        if nonActiveMinimizeProtectionUntil == nil {
            activeWindow = nil
        }
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            setupAXObserver(for: frontApp)
        }
        poll()
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

        if keepProtectedActiveWindowIfNeeded() {
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
                clearNonActiveMinimizeProtection()
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
                clearNonActiveMinimizeProtection()
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
                clearNonActiveMinimizeProtection()
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
                clearNonActiveMinimizeProtection()
                onChange?(false)
            }
            return
        }

        let newRect = CGRect(origin: position, size: size)
        activeWindow = focusedWindow

        // Detect minimization by sudden rect collapse during animation.
        // When a window minimizes, its AX-reported rect shrinks dramatically.
        if let lastRect = activeWindowRect,
           !lastRect.isEmpty,
           newRect.width * newRect.height < lastRect.width * lastRect.height * 0.15 {
            activeWindowRect = nil
            activeWindow = nil
            clearNonActiveMinimizeProtection()
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
        clearNonActiveMinimizeProtection()

        if activeWindowRect == nil || !newRect.equalTo(activeWindowRect!) {
            activeWindowRect = newRect
            onChange?(false)
        }
    }
}
