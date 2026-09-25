import Cocoa

final class OverlayManager: NSObject {
    let settings: ShadeSettings
    let watcher = WindowWatcher()
    private(set) var windows: [OverlayWindow] = []
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastStatus = ""
    private(set) var isTemporarilyPaused = false
    private(set) var shortcutWarning: String? {
        didSet { NotificationCenter.default.post(name: .shadeStatusDidChange, object: self) }
    }

    init(settings: ShadeSettings = ShadeSettings()) { self.settings = settings; super.init() }

    var isEnabled: Bool { get { settings.isEnabled } set { settings.isEnabled = newValue } }
    var dimmingAlpha: CGFloat { get { CGFloat(settings.intensity) } set { settings.intensity = Double(newValue) } }
    var statusText: String {
        if !watcher.hasPermission { return "需要辅助功能权限" }
        if !isEnabled { return "已暂停 · 随时回到专注" }
        if isTemporarilyPaused { return "临时暂停 · 松开 Fn 恢复" }
        if watcher.isSuspended { return "等待桌面唤醒" }
        if let id = watcher.frontAppBundleID, settings.excludedApplications.contains(id) { return "当前应用已排除" }
        if watcher.isFullscreen { return "全屏模式 · 自动暂停" }
        if watcher.activeWindow == nil { return "桌面清晰 · 等待活动窗口" }
        return "正在专注 · \(watcher.frontAppName)"
    }

    func start() {
        createWindows()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .shadeSettingsDidChange, object: settings)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            self?.settings.useDarkAppearance = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        watcher.onChange = { [weak self] in self?.render() }
        watcher.isTrackingEnabled = isEnabled
        watcher.start()
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0) }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsChanged(event); return event
        }
    }

    func stop() {
        watcher.stop()
        watcher.onChange = nil
        windows.forEach { $0.close() }; windows.removeAll()
        if let value = flagsMonitor { NSEvent.removeMonitor(value); flagsMonitor = nil }
        if let value = localFlagsMonitor { NSEvent.removeMonitor(value); localFlagsMonitor = nil }
        NotificationCenter.default.removeObserver(self)
        appearanceObservation = nil
    }

    @objc private func settingsChanged() {
        watcher.isTrackingEnabled = isEnabled
        if !settings.pauseWithFn { isTemporarilyPaused = false }
        if isEnabled { watcher.refresh() } else { render() }
    }
    @objc private func screensChanged() {
        createWindows()
        watcher.scheduleRefresh(settle: true)
    }
    private func createWindows() {
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map(OverlayWindow.init(screen:))
        watcher.ignoredWindowIDs = Set(windows.map { CGWindowID($0.window.windowNumber) })
    }
    private func flagsChanged(_ event: NSEvent) {
        let paused = settings.pauseWithFn && event.modifierFlags.contains(.function)
        if paused != isTemporarilyPaused { isTemporarilyPaused = paused; render() }
    }
    func adjustIntensity(by delta: Double) { settings.intensity += delta }
    func reportShortcutFailures(_ names: [String]) {
        shortcutWarning = names.isEmpty ? nil : "快捷键被其他应用占用：" + names.joined(separator: "、")
    }

    private func render() {
        isTemporarilyPaused = settings.pauseWithFn && CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        let status = statusText
        if lastStatus != status {
            lastStatus = status
            NotificationCenter.default.post(name: .shadeStatusDidChange, object: self)
        }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : settings.fadeDuration
        let excluded = watcher.frontAppBundleID.map { settings.excludedApplications.contains($0) } ?? false
        guard isEnabled, watcher.hasPermission, !watcher.isSuspended,
              !isTemporarilyPaused, !excluded, !watcher.isFullscreen,
              let active = watcher.activeWindow else {
            let userPause = !isEnabled || isTemporarilyPaused || excluded
            windows.forEach { $0.hide(duration: userPause ? duration : 0) }
            return
        }
        let primaryID = CGMainDisplayID()
        let primaryTop = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == primaryID
        }?.frame.maxY ?? 0
        let displays = windows.map { DisplayInfo(id: $0.displayID, frame: DisplayInfo.axFrame(appKitFrame: $0.targetScreen.frame, primaryTop: primaryTop)) }
        let placements = DimmingPolicy.placements(displays: displays, windows: watcher.windows, active: active,
                                                  mode: settings.displayMode, excludedDisplays: settings.excludedDisplays)
        for overlay in windows {
            let placement = placements[overlay.displayID] ?? .hidden
            let level = watcher.windows.first { $0.id == placement.windowID }?.layer ?? active.layer
            if placement == .hidden || settings.intensity == 0 {
                overlay.hide(duration: duration)
            } else {
                let target = watcher.windows.first { $0.id == placement.windowID } ?? active
                let screen = overlay.targetScreen.frame
                let local = CGRect(x: target.frame.minX - screen.minX,
                                   y: primaryTop - target.frame.maxY - screen.minY,
                                   width: target.frame.width, height: target.frame.height)
                overlay.show(placement: placement, focusedRect: local, level: level, color: settings.tint.color,
                             alpha: settings.intensity, duration: duration)
            }
        }
    }

    deinit { stop() }
}
