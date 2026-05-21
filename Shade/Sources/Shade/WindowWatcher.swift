import Cocoa

class WindowWatcher {
    var onChange: ((_ immediate: Bool) -> Void)?
    private(set) var activeWindowRect: CGRect?

    private var timer: Timer?
    private var lastFrontApp: NSRunningApplication?
    private(set) var frontAppBundleID: String?
    private var axObserver: AXObserver?
    private var activeWindow: AXUIElement?

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

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            setupAXObserver(for: frontApp)
        }
    }

    deinit {
        timer?.invalidate()
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

    @objc private func appChanged() {
        nilStreak = 0
        minimizationGracePeriod = nil
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
            onChange?(false)
            return
        }

        // Grace period: after detecting minimization, ignore any rect "recoveries"
        // caused by unstable AX data during the animation.
        if let until = minimizationGracePeriod, Date() < until {
            return
        }
        minimizationGracePeriod = nil

        if activeWindowRect == nil || !newRect.equalTo(activeWindowRect!) {
            activeWindowRect = newRect
            onChange?(false)
        }
    }
}
