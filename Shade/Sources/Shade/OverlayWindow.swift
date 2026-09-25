import Cocoa

private final class DimmingPanel: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Prefer native stacking to preserve the real window silhouette. When AppKit's
/// requested order is not honored, a conservative cutout keeps the focus clear.
final class OverlayWindow {
    let window: NSWindow
    let targetScreen: NSScreen
    let displayID: String
    private let dimLayer = CAShapeLayer()
    private(set) var usesCompatibilityMask = false
    private var hasVerifiedOrder = false
    private var verificationWork: DispatchWorkItem?
    private var lastPlacement: DimmingPlacement?
    private var lastFocusRect: CGRect?
    private var hideWork: DispatchWorkItem?
    private var generation = 0
    private var targetOpacity: Float = 0
    private var targetColor: NSColor?

    init(screen: NSScreen) {
        targetScreen = screen
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() {
            displayID = CFUUIDCreateString(nil, uuid) as String
        } else {
            displayID = String(number)
        }
        window = DimmingPanel(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Transient windows hide in Mission Control. Fullscreen/session
        // suspension is also handled explicitly by the manager.
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        window.setAccessibilityElement(false)
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        view.wantsLayer = true
        dimLayer.frame = view.bounds
        dimLayer.opacity = 0
        dimLayer.fillRule = .evenOdd
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(dimLayer)
    }

    func show(placement: DimmingPlacement, focusedRect: CGRect?, level: Int, color: NSColor, alpha: Double, duration: Double) {
        guard let id = placement.windowID else { hide(duration: duration); return }
        if case .below = placement, focusedRect == nil { hide(duration: 0); return }
        guard !suspendDuringSystemPresentation() else { return }
        let sameTarget = window.isVisible && lastPlacement == placement
        // The pending check validates stacking, not a particular geometry sample.
        // Keep its original deadline while a window is being dragged or resized.
        if sameTarget, verificationWork != nil, window.level.rawValue == level {
            lastFocusRect = focusedRect
            setPath(clearRect: placement.isBelow ? focusedRect : nil)
            transition(to: Float(alpha), color: color, duration: duration)
            return
        }
        generation += 1
        hideWork?.cancel(); hideWork = nil
        verificationWork?.cancel(); verificationWork = nil
        let unchanged = sameTarget && lastFocusRect == focusedRect
        lastPlacement = placement
        lastFocusRect = focusedRect

        // Native occlusion follows the actual window at WindowServer's cadence.
        // A move/resize changes geometry, not stacking; keep the full native mask.
        if sameTarget, hasVerifiedOrder, !usesCompatibilityMask,
           window.level.rawValue == level, orderIsCorrect(placement) == true {
            transition(to: Float(alpha), color: color, duration: duration)
            return
        }
        if unchanged, hasVerifiedOrder, usesCompatibilityMask {
            transition(to: Float(alpha), color: color, duration: duration)
            return
        }
        // Install the new safe region BEFORE any order/flush operation. Even a
        // transient or delayed WindowServer reorder cannot expose an old full mask.
        setPath(clearRect: placement.isBelow ? focusedRect : nil)
        if usesCompatibilityMask && hasVerifiedOrder {
            // Updating the hole does not require raising an already ordered
            // floating window. Repeated ordering fights system overview gestures.
            if !window.isVisible || window.level != .floating {
                window.level = .floating
                window.orderFrontRegardless()
            }
        } else {
            usesCompatibilityMask = true // Safe cutout remains until deferred verification.
            hasVerifiedOrder = false
            window.level = NSWindow.Level(rawValue: level)
            window.order(placement.isBelow ? .below : .above, relativeTo: Int(id))
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.generation == token, self.window.isVisible else { return }
                self.verificationWork = nil
                guard !self.suspendDuringSystemPresentation() else { return }
                if self.orderIsCorrect(placement) == true {
                    self.hasVerifiedOrder = true
                    self.usesCompatibilityMask = false
                    self.setPath(clearRect: nil)
                } else {
                    self.hasVerifiedOrder = true
                    self.usesCompatibilityMask = true
                    self.window.level = .floating
                    self.window.orderFrontRegardless()
                }
            }
            verificationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
        }
        transition(to: Float(alpha), color: color, duration: duration)
    }

    /// Mission Control / App Exposé transform transient windows independently of
    /// AppKit (1x1 at the display center on current macOS). Keep the window ordered
    /// so WindowServer can restore it, but clear its content and ignore thumbnail
    /// geometry until its full display bounds return. No private Dock notifications.
    @discardableResult
    private func suspendDuringSystemPresentation() -> Bool {
        guard window.isVisible else { return false }
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        let primaryTop = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }?.frame.maxY ?? 0
        let expected = DisplayInfo.axFrame(appKitFrame: targetScreen.frame, primaryTop: primaryTop)
        if let bounds = rows.first?[kCGWindowBounds as String] as? NSDictionary,
           let actual = CGRect(dictionaryRepresentation: bounds),
           abs(actual.minX - expected.minX) <= 1, abs(actual.minY - expected.minY) <= 1,
           abs(actual.width - expected.width) <= 1, abs(actual.height - expected.height) <= 1 {
            return false
        }
        generation += 1
        verificationWork?.cancel(); verificationWork = nil
        hideWork?.cancel(); hideWork = nil
        lastPlacement = nil
        hasVerifiedOrder = false
        transition(to: 0, color: targetColor ?? .black, duration: 0)
        dimLayer.removeAllAnimations()
        return true
    }

    private func orderIsCorrect(_ placement: DimmingPlacement) -> Bool? {
        guard let id = placement.windowID else { return nil }
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        guard let own = ids.firstIndex(of: CGWindowID(window.windowNumber)), let target = ids.firstIndex(of: id) else { return nil }
        return placement.isBelow ? own > target : own < target
    }

    private func setPath(clearRect: CGRect?) {
        let path = CGMutablePath()
        path.addRect(dimLayer.bounds)
        // Complete, unclipped rectangle: no false rounded corners at screen edges.
        if let rect = clearRect { path.addRect(rect) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.path = path
        CATransaction.commit()
    }

    func hide(duration: Double = 0) {
        verificationWork?.cancel(); verificationWork = nil
        guard window.isVisible else { return }
        guard hideWork == nil || duration == 0 else { return }
        generation += 1
        hideWork?.cancel()
        hideWork = nil
        transition(to: 0, color: targetColor ?? .black, duration: duration)
        if duration == 0 {
            window.orderOut(nil)
        } else {
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.generation == token else { return }
                self.window.orderOut(nil)
                self.hideWork = nil
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    private func transition(to opacity: Float, color: NSColor, duration: Double) {
        guard targetOpacity != opacity || targetColor != color else { return }
        let fromOpacity = dimLayer.presentation()?.opacity ?? dimLayer.opacity
        let fromColor = dimLayer.presentation()?.fillColor ?? dimLayer.fillColor
        dimLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = opacity
        dimLayer.fillColor = color.cgColor
        CATransaction.commit()
        if duration > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity; fade.toValue = opacity
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dimLayer.add(fade, forKey: "opacity")
            if let fromColor = fromColor, targetColor != color {
                let tint = CABasicAnimation(keyPath: "fillColor")
                tint.fromValue = fromColor; tint.toValue = color.cgColor
                tint.duration = duration
                dimLayer.add(tint, forKey: "fillColor")
            }
        }
        targetOpacity = opacity
        targetColor = color
    }

    func close() {
        verificationWork?.cancel(); verificationWork = nil
        generation += 1
        hideWork?.cancel()
        dimLayer.removeAllAnimations()
        window.close()
    }
}
