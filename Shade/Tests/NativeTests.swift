import Cocoa

@main
@MainActor
struct NativeTests {
    static var count = 0
    static func check(_ name: String, _ value: @autoclosure () -> Bool) {
        guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1
        print("PASS: \(name)")
    }
    static func tick(_ seconds: TimeInterval = 0.06) async {
        NSApp.updateWindows()
        NSApp.windows.forEach { $0.displayIfNeeded() }
        CATransaction.flush()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NativeTestDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    static func runChecks() async throws {
        guard let screen = NSScreen.screens.first else { fatalError("A logged-in desktop is needed for native tests") }
        let overlay = OverlayWindow(screen: screen)
        defer { overlay.close() }
        check("overlay cannot take keyboard focus", !overlay.window.canBecomeKey && !overlay.window.canBecomeMain)
        check("overlay passes mouse events through", overlay.window.ignoresMouseEvents)
        check("overlay adds no artificial desktop shadow", !overlay.window.hasShadow)
        check("overlay starts hidden", !overlay.window.isVisible)
        check("overlay opts into system transient presentation", overlay.window.collectionBehavior.contains(.transient))
        check("overlay has a backing surface", overlay.window.contentView?.layer?.sublayers?.count == 1)

        // Verify public relative ordering against a real window in another process.
        // No AX queries, screen capture, activation or synthetic input are involved.
        func windowList() -> [WindowInfo] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap(WindowInfo.init(dictionary:))
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let external = windowList().first(where: { $0.pid != ownPID && $0.layer == 0 }) else {
            fatalError("Open an ordinary app window before running integration tests")
        }
        let focusRect = CGRect(x: external.frame.minX - screen.frame.minX,
                               y: screen.frame.maxY - external.frame.maxY - screen.frame.minY,
                               width: external.frame.width, height: external.frame.height)
        overlay.show(placement: .below(external.id), focusedRect: focusRect, level: 0, color: .black, alpha: 0.01, duration: 0)
        let surface = overlay.window.contentView?.layer?.sublayers?.first as? CAShapeLayer
        check("focus is clear before deferred order verification", surface?.path?.contains(CGPoint(x: focusRect.midX, y: focusRect.midY), using: .evenOdd) == false)
        await tick()
        var ids = windowList().map(\.id)
        let overlayID = CGWindowID(overlay.window.windowNumber)
        check("WindowServer sees the native overlay", ids.contains(overlayID))
        if overlay.usesCompatibilityMask {
            let shape = overlay.window.contentView?.layer?.sublayers?.first as? CAShapeLayer
            check("compatibility mode leaves the active content clear", shape?.path?.contains(CGPoint(x: focusRect.midX, y: focusRect.midY), using: .evenOdd) == false)
            print("Native relative ordering unavailable in this session; verified conservative compatibility mask.")
        } else {
            check("overlay is below a real external window", ids.firstIndex(of: external.id)! < ids.firstIndex(of: overlayID)!)
            // Geometry changes must not replace native window occlusion with a
            // chasing cutout, even when updates arrive before the 40ms verifier.
            for step in 1...4 {
                let moved = focusRect.offsetBy(dx: CGFloat(step * 12), dy: CGFloat(step * 4))
                overlay.show(placement: .below(external.id), focusedRect: moved, level: 0, color: .black, alpha: 0.01, duration: 0.18)
                check("native ordering survives movement sample \(step)", !overlay.usesCompatibilityMask && overlay.window.level == .normal)
                check("native movement preserves system occlusion \(step)", surface?.path?.contains(CGPoint(x: moved.midX, y: moved.midY), using: .evenOdd) == true)
                await tick(0.012)
            }
            check("movement never starts a brightness fade", surface?.animationKeys()?.isEmpty != false && surface?.opacity == 0.01)

            let settlingOverlay = OverlayWindow(screen: screen)
            for step in 0...7 {
                settlingOverlay.show(placement: .below(external.id), focusedRect: focusRect.offsetBy(dx: CGFloat(step * 5), dy: 0),
                                     level: 0, color: .black, alpha: 0.01, duration: 0)
                await tick(0.012)
            }
            check("continuous movement cannot starve initial order verification", !settlingOverlay.usesCompatibilityMask)
            settlingOverlay.close()
        }
        overlay.show(placement: .above(external.id), focusedRect: nil, level: 0, color: .black, alpha: 0.01, duration: 0)
        await tick()
        ids = windowList().map(\.id)
        check("inactive-display placement can cover the external window", ids.firstIndex(of: overlayID)! < ids.firstIndex(of: external.id)!)
        overlay.hide(duration: 0.04)
        overlay.show(placement: .below(external.id), focusedRect: focusRect, level: 0, color: .black, alpha: 0.01, duration: 0)
        check("full-mask to focus transition installs a safe hole immediately", surface?.path?.contains(CGPoint(x: focusRect.midX, y: focusRect.midY), using: .evenOdd) == false)
        await tick(0.08)
        check("a stale fade-out cannot hide a newly shown overlay", overlay.window.isVisible)
        overlay.hide(duration: 0)
        check("immediate suspension removes the overlay", !overlay.window.isVisible)

        // WindowServer changes transient windows to 1x1 in Mission Control.
        // Resize our test window to reproduce that server geometry; exercise real
        // windows/layers and delayed ordering without needing synthetic gestures.
        let overviewOverlay = OverlayWindow(screen: screen)
        defer { overviewOverlay.close() }
        let originalRect = CGRect(x: 100, y: 100, width: 600, height: 400)
        let thumbnailRect = CGRect(x: 50, y: 60, width: 300, height: 200)
        overviewOverlay.show(placement: .below(external.id), focusedRect: originalRect, level: 0, color: .black, alpha: 0.01, duration: 0)
        let overviewSurface = overviewOverlay.window.contentView!.layer!.sublayers!.first as! CAShapeLayer
        overviewOverlay.window.setFrame(CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 1, height: 1), display: true)
        overviewOverlay.show(placement: .below(external.id), focusedRect: thumbnailRect, level: 0, color: .black, alpha: 0.01, duration: 0)
        check("overview clears dimming without ordering the transient window out", overviewSurface.opacity == 0 && overviewOverlay.window.isVisible)
        check("overview never adopts thumbnail coordinates", overviewSurface.path?.contains(CGPoint(x: 650, y: 450), using: .evenOdd) == false)
        await tick(0.08)
        check("deferred ordering cannot restore dimming during overview", overviewSurface.opacity == 0)
        overviewOverlay.window.setFrame(screen.frame, display: true)
        await tick()
        overviewOverlay.show(placement: .below(external.id), focusedRect: originalRect, level: 0, color: .black, alpha: 0.01, duration: 0)
        check("normal desktop restores dimming with a freshly aligned focus", overviewSurface.opacity == 0.01 && overviewSurface.path?.contains(CGPoint(x: 650, y: 450), using: .evenOdd) == false)
        overviewOverlay.hide()

        overviewOverlay.show(placement: .below(external.id), focusedRect: originalRect, level: 0, color: .black, alpha: 0.01, duration: 0)
        overviewOverlay.window.setFrame(CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 1, height: 1), display: true)
        await tick(0.08)
        check("order verification itself respects a newly started overview", overviewSurface.opacity == 0)
        overviewOverlay.hide()

        // A controlled real window exercises actual WindowServer movement without
        // moving any of the user's windows or relying on AX/synthetic input.
        let movingWindow = NSWindow(contentRect: CGRect(x: screen.frame.minX + 120, y: screen.frame.minY + 120, width: 320, height: 220),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        movingWindow.isReleasedWhenClosed = false
        movingWindow.ignoresMouseEvents = true
        movingWindow.backgroundColor = .clear
        movingWindow.isOpaque = false
        movingWindow.orderFrontRegardless()
        let movingOverlay = OverlayWindow(screen: screen)
        let movingID = CGWindowID(movingWindow.windowNumber)
        movingOverlay.show(placement: .below(movingID), focusedRect: CGRect(x: 120, y: 120, width: 320, height: 220), level: 0, color: .black, alpha: 0.01, duration: 0)
        await tick()
        var movementStayedNative = !movingOverlay.usesCompatibilityMask
        var movementStayedBelow = true
        for step in 1...12 {
            movingWindow.setFrameOrigin(CGPoint(x: screen.frame.minX + 120 + CGFloat(step * 8), y: screen.frame.minY + 120 + CGFloat(step * 3)))
            await tick(0.012)
            let rect = movingWindow.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            movingOverlay.show(placement: .below(movingID), focusedRect: rect, level: 0, color: .black, alpha: 0.01, duration: 0.18)
            movementStayedNative = movementStayedNative && !movingOverlay.usesCompatibilityMask
            let ordered = windowList().map(\.id)
            if let targetIndex = ordered.firstIndex(of: movingID), let maskIndex = ordered.firstIndex(of: CGWindowID(movingOverlay.window.windowNumber)) {
                movementStayedBelow = movementStayedBelow && targetIndex < maskIndex
            } else { movementStayedBelow = false }
        }
        check("real window movement keeps native rendering", movementStayedNative)
        check("real window movement keeps the overlay below its target", movementStayedBelow)
        movingOverlay.close()
        movingWindow.close()

        let domain = "ShadeUIQA.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = OverlayManager(settings: ShadeSettings(defaults: defaults))
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let quick = PreferencesViewController(overlayManager: manager)
            _ = quick.view
            let settings = SettingsViewController(manager: manager)
            for (kind, controller, size) in [("quick", quick as NSViewController, quick.preferredContentSize),
                                             ("settings", settings as NSViewController, NSSize(width: 652, height: 552))] {
                let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                host.appearance = NSAppearance(named: appearance)
                host.contentViewController = controller
                host.setContentSize(size)
                controller.view.frame = NSRect(origin: .zero, size: size)
                controller.view.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                check("\(kind) \(name) has a resolved root layout", !controller.view.hasAmbiguousLayout)
                guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else { fatalError("No bitmap") }
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let path = output.appendingPathComponent("\(kind)-\(name).png")
                // Flatten the transparent NSView cache over the window's actual
                // surface color for a readable offscreen layout proof.
                let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
                    pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                flat.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
                host.appearance?.performAsCurrentDrawingAppearance {
                    (name == "light" ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)).setFill()
                    NSRect(origin: .zero, size: size).fill()
                    let image = NSImage(size: size)
                    image.addRepresentation(bitmap)
                    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
                }
                NSGraphicsContext.restoreGraphicsState()
                try flat.representation(using: .png, properties: [:])!.write(to: path)
                print("Rendered: \(path.path)")
                host.close()
            }
        }
        print("\(count) native checks passed")
    }
}

private final class NativeTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await NativeTests.runChecks(); exit(0) }
            catch { fputs("Native tests failed: \(error)\n", stderr); exit(1) }
        }
    }
}
