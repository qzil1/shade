import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, AccessibilityPromptWindowDelegate {
    private var overlayManager: OverlayManager!
    private var statusBarController: StatusBarController!
    private var promptWindow: AccessibilityPromptWindow?
    private var hotKeyManager: HotKeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        overlayManager = OverlayManager()
        overlayManager.start()
        statusBarController = StatusBarController(overlayManager: overlayManager)
        hotKeyManager = HotKeyManager()
        hotKeyManager.onToggleDimming = { [weak self] in self?.overlayManager.isEnabled.toggle() }
        hotKeyManager.onDecreaseAlpha = { [weak self] in self?.overlayManager.adjustIntensity(by: -0.05) }
        hotKeyManager.onIncreaseAlpha = { [weak self] in self?.overlayManager.adjustIntensity(by: 0.05) }
        hotKeyManager.onToggleMultiDisplay = { [weak self] in
            guard let settings = self?.overlayManager.settings else { return }
            let modes = DisplayMode.allCases
            let current = modes.firstIndex(of: settings.displayMode) ?? 0
            settings.displayMode = modes[(current + 1) % modes.count]
        }
        overlayManager.reportShortcutFailures(hotKeyManager.register())
        NotificationCenter.default.addObserver(self, selector: #selector(permissionChanged), name: .shadeStatusDidChange, object: overlayManager)
        if !overlayManager.watcher.hasPermission {
            promptWindow = AccessibilityPromptWindow()
            promptWindow?.delegate = self
            promptWindow?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc private func permissionChanged() {
        if overlayManager.watcher.hasPermission {
            promptWindow?.close()
            promptWindow = nil
        }
    }
    func accessibilityPromptWindowDidClose() { promptWindow = nil }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.showSettings()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.unregister()
        overlayManager?.stop()
        NotificationCenter.default.removeObserver(self)
    }
}
