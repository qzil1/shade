import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, AccessibilityPromptWindowDelegate {
    var overlayManager: OverlayManager!
    var statusBarController: StatusBarController!
    var promptWindow: AccessibilityPromptWindow?
    var hotKeyManager: HotKeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )

        overlayManager = OverlayManager()
        statusBarController = StatusBarController(overlayManager: overlayManager)
        overlayManager.start()

        hotKeyManager = HotKeyManager()
        hotKeyManager.onToggleDimming = { [weak self] in
            self?.overlayManager.isEnabled.toggle()
        }
        hotKeyManager.onDecreaseAlpha = { [weak self] in
            self?.overlayManager.dimmingAlpha = max(0.1, (self?.overlayManager.dimmingAlpha ?? 0.55) - 0.05)
        }
        hotKeyManager.onIncreaseAlpha = { [weak self] in
            self?.overlayManager.dimmingAlpha = min(0.9, (self?.overlayManager.dimmingAlpha ?? 0.55) + 0.05)
        }
        hotKeyManager.onToggleMultiDisplay = { [weak self] in
            self?.overlayManager.dimAdditionalDisplays.toggle()
        }
        hotKeyManager.register()

        if !trusted {
            overlayManager.isEnabled = false
            promptWindow = AccessibilityPromptWindow()
            promptWindow?.delegate = self
            promptWindow?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func accessibilityPromptWindowDidClose() {
        promptWindow = nil
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
        overlayManager.isEnabled = trusted
    }
}
