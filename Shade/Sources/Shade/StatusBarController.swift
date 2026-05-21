import Cocoa

class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem
    private let overlayManager: OverlayManager
    private let popover = NSPopover()
    private var eventMonitor: EventMonitor?

    init(overlayManager: OverlayManager) {
        self.overlayManager = overlayManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.title = "◐"
            button.action = #selector(handleStatusBarClick)
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        popover.contentViewController = PreferencesViewController(overlayManager: overlayManager)
        popover.behavior = .transient
        popover.delegate = self

        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    @objc func handleStatusBarClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseDown || event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        if let button = statusItem.button {
            if let prefsVC = popover.contentViewController as? PreferencesViewController {
                prefsVC.refreshFromManager()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            eventMonitor?.start()
        }
    }

    func closePopover() {
        popover.performClose(nil)
        eventMonitor?.stop()
    }

    func popoverDidClose(_ notification: Notification) {
        eventMonitor?.stop()
    }

    // MARK: - Context Menu

    private func showContextMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: overlayManager.isEnabled ? "停用遮罩" : "启用遮罩",
            action: #selector(toggleDimming),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let decreaseItem = NSMenuItem(
            title: "降低强度",
            action: #selector(decreaseAlpha),
            keyEquivalent: ""
        )
        decreaseItem.target = self
        menu.addItem(decreaseItem)

        let increaseItem = NSMenuItem(
            title: "增加强度",
            action: #selector(increaseAlpha),
            keyEquivalent: ""
        )
        increaseItem.target = self
        menu.addItem(increaseItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(
            title: "偏好设置...",
            action: #selector(showPreferences),
            keyEquivalent: ""
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "退出 Shade",
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleDimming() {
        overlayManager.isEnabled.toggle()
    }

    @objc private func decreaseAlpha() {
        overlayManager.dimmingAlpha = max(0.1, overlayManager.dimmingAlpha - 0.05)
    }

    @objc private func increaseAlpha() {
        overlayManager.dimmingAlpha = min(0.9, overlayManager.dimmingAlpha + 0.05)
    }

    @objc private func showPreferences() {
        showPopover()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
