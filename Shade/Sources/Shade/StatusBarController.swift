import Cocoa

final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let manager: OverlayManager
    private let popover = NSPopover()
    private var settingsWindow: SettingsWindowController?
    private var scrollMonitor: Any?

    init(overlayManager: OverlayManager) {
        manager = overlayManager
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Shade 专注调光")
            button.image?.isTemplate = true
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Shade 专注调光")
        }
        let controller = PreferencesViewController(overlayManager: overlayManager)
        controller.onShowSettings = { [weak self] in self?.showSettings() }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        // Only intercept scrolling while the pointer is over this status item.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let button = self.statusItem.button,
                  event.window === button.window,
                  button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return event }
            if event.phase == .ended || event.momentumPhase != [] { return nil }
            let delta = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.003 : 0.025)
            self.manager.adjustIntensity(by: delta)
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .shadeSettingsDidChange, object: manager.settings)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .shadeStatusDidChange, object: manager)
        refresh()
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showMenu(); return }
        if event.clickCount >= 2 {
            popover.performClose(nil)
            manager.isEnabled.toggle()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            (popover.contentViewController as? PreferencesViewController)?.refreshFromManager()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    @objc private func refresh() {
        statusItem.button?.alphaValue = manager.isEnabled ? 1 : 0.5
        statusItem.button?.toolTip = "Shade · \(manager.statusText)\n背景变暗 \(Int(manager.settings.intensity * 100))% · 双击开关"
    }
    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil { settingsWindow = SettingsWindowController(manager: manager) }
        settingsWindow?.showWindow(nil)
    }
    private func showMenu() {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        item(manager.isEnabled ? "暂停调光" : "启用调光", #selector(toggle))
        item("增强背景变暗", #selector(increase))
        item("减弱背景变暗", #selector(decrease))
        menu.addItem(.separator())
        item("设置…", #selector(showSettings))
        if !manager.watcher.hasPermission { item("开启辅助功能权限…", #selector(permissions)) }
        menu.addItem(.separator())
        item("退出 Shade", #selector(quit))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    @objc private func toggle() { manager.isEnabled.toggle() }
    @objc private func increase() { manager.adjustIntensity(by: 0.05) }
    @objc private func decrease() { manager.adjustIntensity(by: -0.05) }
    @objc private func permissions() { PermissionSupport.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    deinit {
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
