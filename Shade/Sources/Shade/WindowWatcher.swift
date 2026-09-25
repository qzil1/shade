import Cocoa

final class WindowWatcher {
    var onChange: (() -> Void)?
    var ignoredWindowIDs: Set<CGWindowID> = []
    var isTrackingEnabled = true
    private(set) var activeWindow: WindowInfo?
    private(set) var windows: [WindowInfo] = []
    private(set) var frontAppBundleID: String?
    private(set) var frontAppName = ""
    private(set) var hasPermission = false
    private(set) var isFullscreen = false
    private(set) var isSuspended = false

    private var timer: Timer?
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?
    private var observedPID: pid_t?
    private var resolvedWindowID: CGWindowID?
    private var lastExternalFocus: (id: CGWindowID, bundleID: String?, name: String, fullscreen: Bool)?
    private var refreshWork: DispatchWorkItem?
    private var settlingWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private let windowNotifications = [kAXMovedNotification, kAXResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification]

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ action: @escaping () -> Void) {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in action() })
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.scheduleRefresh(settle: true) }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] in self?.scheduleRefresh(settle: true) }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] in self?.scheduleRefresh() }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.activeWindow = nil
            self?.onChange?()
            self?.scheduleRefresh(settle: true)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(name) { [weak self] in self?.suspend() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(name) { [weak self] in self?.isSuspended = false; self?.scheduleRefresh(settle: true) }
        }
        // AX handles normal operation; a low-frequency watchdog repairs missed
        // notifications and discovers permission changes without relaunching.
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] _ in
            self?.scheduleRefresh(settle: true)
        }
        refresh()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        refreshWork?.cancel(); refreshWork = nil
        settlingWork?.cancel(); settlingWork = nil
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor); mouseMonitor = nil }
        notificationTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notificationTokens.removeAll()
        removeObserver()
        activeWindow = nil
    }

    private func suspend() {
        isSuspended = true
        refreshWork?.cancel(); refreshWork = nil
        settlingWork?.cancel(); settlingWork = nil
        activeWindow = nil
        onChange?()
    }

    func scheduleRefresh(settle: Bool = false) {
        if refreshWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.refreshWork = nil
                self?.refresh()
            }
            refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
        }
        if settle {
            settlingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            settlingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
        }
    }

    func refresh() {
        hasPermission = AXIsProcessTrusted()
        guard !isSuspended, isTrackingEnabled, hasPermission else {
            activeWindow = nil
            onChange?()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            activeWindow = nil; onChange?(); return
        }
        let dictionaries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windows = dictionaries.compactMap(WindowInfo.init(dictionary:)).filter { !ignoredWindowIDs.contains($0.id) }
        isFullscreen = false
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            let own = NSApp.keyWindow ?? NSApp.mainWindow
            if let ownWindow = own.flatMap({ key in windows.first { $0.id == CGWindowID(key.windowNumber) } }) {
                activeWindow = ownWindow
                frontAppBundleID = app.bundleIdentifier
                frontAppName = "Shade"
            } else if let previous = lastExternalFocus {
                // A high-level popover is not an ordinary focus target. Keep the
                // desktop preview live without accidentally targeting our panel.
                activeWindow = windows.first { $0.id == previous.id }
                frontAppBundleID = previous.bundleID
                frontAppName = previous.name
                isFullscreen = previous.fullscreen
            } else { activeWindow = nil }
            onChange?()
            return
        }
        frontAppBundleID = app.bundleIdentifier
        frontAppName = app.localizedName ?? "当前应用"
        if observedPID != app.processIdentifier { observe(app: app) }
        guard let axApp = observedApp,
              let focused = element(kAXFocusedWindowAttribute, of: axApp) else {
            observe(window: nil)
            lastExternalFocus = nil
            activeWindow = nil; onChange?(); return
        }
        observe(window: focused)
        if bool(kAXMinimizedAttribute, of: focused) {
            lastExternalFocus = nil
            activeWindow = nil; onChange?(); return
        }
        isFullscreen = bool("AXFullScreen", of: focused)
        // AX and Quartz geometries are sampled at different instants. Once the
        // AX identity is known, use its CG ID so dragging never drops the target.
        let bounds = resolvedWindowID == nil ? frame(of: focused) : nil
        activeWindow = WindowSelection.resolve(pid: app.processIdentifier, frame: bounds,
                                                knownWindowID: resolvedWindowID, windows: windows)
        if let active = activeWindow {
            resolvedWindowID = active.id
            lastExternalFocus = (active.id, frontAppBundleID, frontAppName, isFullscreen)
        } else {
            // Some apps replace a CG backing surface without replacing their AX
            // element. Hide now, then allow a fresh geometry match next time.
            resolvedWindowID = nil
            lastExternalFocus = nil
        }
        onChange?()
    }

    private func observe(app: NSRunningApplication) {
        removeObserver()
        observedPID = app.processIdentifier
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.08)
        observedApp = axApp
        var value: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context = context else { return }
            let watcher = Unmanaged<WindowWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.scheduleRefresh()
        }
        guard AXObserverCreate(app.processIdentifier, callback, &value) == .success, let value = value else { return }
        observer = value
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(value, axApp, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
    }

    private func observe(window: AXUIElement?) {
        if let old = observedWindow, let new = window, CFEqual(old, new) { return }
        if let old = observedWindow, let observer = observer {
            for name in windowNotifications { AXObserverRemoveNotification(observer, old, name as CFString) }
        }
        resolvedWindowID = nil
        observedWindow = window
        if let window = window, let observer = observer {
            AXUIElementSetMessagingTimeout(window, 0.08)
            for name in windowNotifications {
                AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    private func removeObserver() {
        observe(window: nil)
        if let observer = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; observedApp = nil; observedPID = nil
    }

    private func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private func element(_ name: String, of target: AXUIElement) -> AXUIElement? {
        guard let result = value(name, of: target), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private func bool(_ name: String, of target: AXUIElement) -> Bool { (value(name, of: target) as? NSNumber)?.boolValue ?? false }
    private func frame(of target: AXUIElement) -> CGRect? {
        guard let position = value(kAXPositionAttribute, of: target), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(kAXSizeAttribute, of: target), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    deinit { stop() }
}
