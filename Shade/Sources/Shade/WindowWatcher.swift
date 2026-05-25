import Cocoa

class WindowWatcher {
    var onChange: ((_ immediate: Bool) -> Void)?
    private(set) var activeWindowRect: CGRect?

    private var timer: Timer?
    private var lastFrontApp: NSRunningApplication?
    private(set) var frontAppBundleID: String?
    private var axObserver: AXObserver?
    private var activeWindow: AXUIElement?
    private var mouseDownMonitor: Any?
    // Require 2 consecutive AX failures before treating as "no active window".
    private var nilStreak: Int = 0
    private let nilThreshold: Int = 2

    // After detecting minimization, ignore rect recoveries for 0.4s to avoid
    // flicker caused by unstable AX data during the minimize animation.
    private var minimizationGracePeriod: Date?

    // Movement detection: hide mask while window is being dragged/resized.
    private var isMoving: Bool = false
    private var stableCount: Int = 0
    private var lastPolledRect: CGRect?
    private let moveThreshold: CGFloat = 2.0
    private let stableThreshold: Int = 3

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

    private func handleMouseDown(_ event: NSEvent) {
        guard activeWindowRect != nil,
              let activeWindow = activeWindow,
              let cgEvent = event.cgEvent else {
            return
        }

        guard let hitElement = elementAtScreenPosition(cgEvent.location),
              let minimizeButton = minimizeButtonElement(from: hitElement),
              let containingWindow = containingWindow(of: minimizeButton),
              CFEqual(containingWindow, activeWindow) else {
            return
        }

        nilStreak = 0
        activeWindowRect = nil
        self.activeWindow = nil
        minimizationGracePeriod = Date().addingTimeInterval(0.4)
        onChange?(true)
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

    private func isWindowOnScreen(_ window: AXUIElement) -> Bool {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "AXUIElementGetWindow") else {
            return true
        }

        typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
        let fn = unsafeBitCast(sym, to: AXUIElementGetWindowFunc.self)

        var windowID: UInt32 = 0
        guard fn(window, &windowID) == 0 else {
            return true
        }

        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        return windowList?.contains { dict in
            (dict[kCGWindowNumber as String] as? UInt32) == windowID
        } ?? true
    }

    @objc private func appChanged() {
        nilStreak = 0
        minimizationGracePeriod = nil
        lastPolledRect = nil
        isMoving = false
        stableCount = 0
        activeWindow = nil
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
                minimizationGracePeriod = nil
                onChange?(false)
            }
            return
        }
        nilStreak = 0
        let focusedWindow = axWindow as! AXUIElement

        // If the focused window is not actually visible on the current space,
        // treat it as no active window (e.g. during a space swipe).
        if !isWindowOnScreen(focusedWindow) {
            if activeWindowRect != nil {
                activeWindowRect = nil
                activeWindow = nil
                onChange?(true)
            }
            return
        }

        // Check minimized first: if true, skip reading position/size entirely.
        var minimizedValue: AnyObject?
        let minimizedResult = AXUIElementCopyAttributeValue(focusedWindow, "AXMinimized" as CFString, &minimizedValue)
        if minimizedResult == .success,
           let minimized = minimizedValue as? NSNumber,
           minimized.boolValue {
            if activeWindowRect != nil {
                activeWindowRect = nil
                activeWindow = nil
                minimizationGracePeriod = Date().addingTimeInterval(0.4)
                onChange?(true)
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
            minimizationGracePeriod = Date().addingTimeInterval(0.4)
            onChange?(true)
            return
        }

        // Grace period: after detecting minimization, ignore any rect "recoveries"
        // caused by unstable AX data during the animation.
        if let until = minimizationGracePeriod, Date() < until {
            return
        }
        minimizationGracePeriod = nil

        // Movement detection: hide mask while window is being dragged/resized.
        if !isMoving {
            if let last = lastPolledRect,
               (abs(newRect.origin.x - last.origin.x) > moveThreshold ||
                abs(newRect.origin.y - last.origin.y) > moveThreshold ||
                abs(newRect.width - last.width) > moveThreshold ||
                abs(newRect.height - last.height) > moveThreshold) {
                isMoving = true
                stableCount = 0
            }
        } else {
            if let last = lastPolledRect, newRect.equalTo(last) {
                stableCount += 1
            } else {
                stableCount = 0
            }

            if stableCount >= stableThreshold {
                isMoving = false
                stableCount = 0
            }
        }
        lastPolledRect = newRect

        if isMoving {
            if activeWindowRect != nil {
                activeWindowRect = nil
                onChange?(true)
            }
            return
        }

        if activeWindowRect == nil || !newRect.equalTo(activeWindowRect!) {
            activeWindowRect = newRect
            onChange?(false)
        }
    }
}
