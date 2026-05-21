import Cocoa

class OverlayWindow {
    let window: NSWindow
    let targetScreen: NSScreen
    let screenNumber: CGDirectDisplayID
    private var dimLayer: CAShapeLayer?
    private var hideWorkItem: DispatchWorkItem?
    private var hideToken: UUID?

    init(screen: NSScreen) {
        self.targetScreen = screen
        self.screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.setFrame(screen.frame, display: false)

        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        w.contentView = view

        self.window = w
    }

    func showMask(holeRect: CGRect?, alpha: CGFloat, duration: Double = 0.12, cornerRadius: CGFloat = 14) {
        guard let contentView = window.contentView else { return }
        let bounds = contentView.bounds

        // Cancel any pending hide cleanup so the layer doesn't disappear
        // right after we make it visible again.
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hideToken = nil

        // Cancel in-flight opacity fade and restore full visibility immediately.
        dimLayer?.removeAnimation(forKey: "opacity")
        dimLayer?.isHidden = false
        dimLayer?.opacity = 1

        let path = CGMutablePath()
        path.addRect(bounds)

        // Always add a second path so the topology stays identical.
        // This lets Core Animation interpolate smoothly.
        if let hole = holeRect {
            path.addPath(CGPath(roundedRect: hole, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        } else {
            path.addRect(CGRect(x: -1, y: -1, width: 0, height: 0))
        }

        let isNewLayer = dimLayer == nil
        if dimLayer == nil {
            let layer = CAShapeLayer()
            layer.fillRule = .evenOdd
            layer.frame = contentView.bounds
            contentView.wantsLayer = true
            if let backingLayer = contentView.layer {
                backingLayer.addSublayer(layer)
            }
            dimLayer = layer
        } else {
            dimLayer?.frame = contentView.bounds
        }

        guard let dimLayer = dimLayer else { return }

        // Remove stale animations so they don't conflict with the new target
        dimLayer.removeAnimation(forKey: "path")
        dimLayer.removeAnimation(forKey: "fillColor")

        let targetColor = NSColor.black.withAlphaComponent(alpha).cgColor

        if duration > 0 && !isNewLayer {
            let fromPath = dimLayer.presentation()?.path ?? dimLayer.path
            let fromColor = dimLayer.presentation()?.fillColor ?? dimLayer.fillColor

            let pathAnim = CABasicAnimation(keyPath: #keyPath(CAShapeLayer.path))
            pathAnim.fromValue = fromPath
            pathAnim.toValue = path
            pathAnim.duration = duration
            pathAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimLayer.add(pathAnim, forKey: "path")

            let alphaAnim = CABasicAnimation(keyPath: #keyPath(CAShapeLayer.fillColor))
            alphaAnim.fromValue = fromColor
            alphaAnim.toValue = targetColor
            alphaAnim.duration = duration
            alphaAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimLayer.add(alphaAnim, forKey: "fillColor")
        }

        dimLayer.path = path
        dimLayer.fillColor = targetColor
        dimLayer.isHidden = false
    }

    func hideMask(duration: Double = 0.12) {
        guard let layer = dimLayer, !layer.isHidden else { return }

        // Deduplicate overlapping hide calls.
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hideToken = nil

        if duration > 0 {
            let opacityAnim = CABasicAnimation(keyPath: #keyPath(CALayer.opacity))
            opacityAnim.fromValue = layer.presentation()?.opacity ?? layer.opacity
            opacityAnim.toValue = 0
            opacityAnim.duration = duration
            opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            opacityAnim.fillMode = .forwards
            opacityAnim.isRemovedOnCompletion = false
            layer.add(opacityAnim, forKey: "opacity")

            let token = UUID()
            hideToken = token
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.hideToken == token else { return }
                layer.isHidden = true
                layer.opacity = 1
                layer.removeAllAnimations()
                self.hideWorkItem = nil
                self.hideToken = nil
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
        } else {
            layer.isHidden = true
        }
    }

    func orderFront() {
        window.orderFront(nil)
    }

    func close() {
        window.close()
    }
}
