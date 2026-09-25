import Cocoa

// Small native layout helpers shared by the quick panel and settings window.
enum ShadeUI {
    static let accent = NSColor(srgbRed: 0.49, green: 0.40, blue: 0.88, alpha: 1)
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        view.textColor = color
        view.lineBreakMode = .byTruncatingTail
        return view
    }
    static func detail(_ text: String) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: 12)
        view.textColor = .secondaryLabelColor
        return view
    }
    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    static func row(_ left: NSView, _ right: NSView) -> NSStackView { stack([left, spacer(), right], vertical: false) }
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 20) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
    static func stretch(_ views: [NSView], in stack: NSStackView) {
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
}

final class PreferencesViewController: NSViewController {
    let overlayManager: OverlayManager
    var onShowSettings: (() -> Void)?
    private let preview = FocusPreviewView()
    private let enableSwitch = NSSwitch()
    private let intensity = NSSlider(value: 0.55, minValue: 0, maxValue: 0.9, target: nil, action: nil)
    private let percentage = ShadeUI.label("55%", size: 13, weight: .semibold)
    private let status = ShadeUI.label("", size: 11, color: .secondaryLabelColor)
    private let palette = NSSegmentedControl(labels: ShadeTint.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let permissionButton = NSButton(title: "开启辅助功能权限…", target: nil, action: nil)

    init(overlayManager: OverlayManager) {
        self.overlayManager = overlayManager
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 362, height: 548))
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Shade")
        mark.contentTintColor = ShadeUI.accent
        mark.symbolConfiguration = .init(pointSize: 30, weight: .medium)
        mark.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let heading = ShadeUI.stack([ShadeUI.label("Shade", size: 22, weight: .semibold),
                                     ShadeUI.label("让注意力，留在眼前。", size: 11, color: .secondaryLabelColor)], spacing: 4)
        let header = ShadeUI.stack([mark, heading, ShadeUI.spacer(), ShadeUI.label("专注空间", size: 10, weight: .medium, color: ShadeUI.accent)], vertical: false, spacing: 12)
        preview.heightAnchor.constraint(equalToConstant: 156).isActive = true
        preview.setAccessibilityLabel("调光效果示意：前景窗口保持清晰，背景随强度变暗")
        let toggleText = ShadeUI.stack([ShadeUI.label("专注调光", size: 14, weight: .semibold), status], spacing: 5)
        enableSwitch.target = self; enableSwitch.action = #selector(toggleChanged)
        enableSwitch.setAccessibilityLabel("启用专注调光")
        let toggleRow = ShadeUI.row(toggleText, enableSwitch)
        percentage.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        percentage.textColor = ShadeUI.accent
        let intensityHeader = ShadeUI.row(ShadeUI.label("背景变暗", weight: .medium), percentage)
        intensity.target = self; intensity.action = #selector(intensityChanged)
        intensity.isContinuous = true
        intensity.setAccessibilityLabel("背景变暗强度")
        let hints = ShadeUI.row(ShadeUI.label("通透", size: 10, color: .tertiaryLabelColor),
                                ShadeUI.label("沉浸", size: 10, color: .tertiaryLabelColor))
        let intensityGroup = ShadeUI.stack([intensityHeader, intensity, hints], spacing: 5)
        ShadeUI.stretch([intensityHeader, intensity, hints], in: intensityGroup)
        palette.target = self; palette.action = #selector(tintChanged)
        palette.segmentDistribution = .fillEqually
        palette.setAccessibilityLabel("调光色调")
        let colors = ShadeUI.stack([ShadeUI.label("色调", size: 12, weight: .medium), palette], spacing: 8)
        ShadeUI.stretch([palette], in: colors)
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self; permissionButton.action = #selector(openPermissions)
        permissionButton.contentTintColor = .systemOrange
        let settingsButton = NSButton(title: "设置…", target: self, action: #selector(showSettings))
        settingsButton.bezelStyle = .recessed
        settingsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        settingsButton.imagePosition = .imageLeading
        let quit = NSButton(image: NSImage(systemSymbolName: "power", accessibilityDescription: "退出 Shade")!, target: self, action: #selector(quitApp))
        quit.bezelStyle = .recessed
        quit.toolTip = "退出 Shade"
        let footer = ShadeUI.row(settingsButton, quit)
        let hint = ShadeUI.label("按住 fn 暂时看清全部窗口", size: 11, color: .tertiaryLabelColor)
        let contents = ShadeUI.stack([header, preview, toggleRow, ShadeUI.separator(), intensityGroup,
                                      colors, permissionButton, hint, ShadeUI.separator(), footer], spacing: 14)
        ShadeUI.pin(contents, in: view)
        ShadeUI.stretch(contents.arrangedSubviews.filter { $0 !== hint && $0 !== permissionButton }, in: contents)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFromManager), name: .shadeSettingsDidChange, object: overlayManager.settings)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFromManager), name: .shadeStatusDidChange, object: overlayManager)
        refreshFromManager()
    }

    @objc func refreshFromManager() {
        guard isViewLoaded else { return }
        let settings = overlayManager.settings
        enableSwitch.state = settings.isEnabled ? .on : .off
        intensity.doubleValue = settings.intensity
        percentage.stringValue = "\(Int((settings.intensity * 100).rounded()))%"
        status.stringValue = overlayManager.statusText
        permissionButton.isHidden = overlayManager.watcher.hasPermission
        palette.selectedSegment = ShadeTint.allCases.firstIndex(of: settings.tint) ?? 0
        preview.intensity = settings.isEnabled ? settings.intensity : 0
        preview.tint = settings.tint.color
        preview.needsDisplay = true
        // The permission call-to-action only takes space while it is needed.
        preferredContentSize = NSSize(width: 362, height: permissionButton.isHidden ? 528 : 568)
    }
    @objc private func toggleChanged() { overlayManager.isEnabled = enableSwitch.state == .on }
    @objc private func intensityChanged() { overlayManager.settings.intensity = intensity.doubleValue }
    @objc private func tintChanged() { overlayManager.settings.tint = ShadeTint.allCases[palette.selectedSegment] }
    @objc private func openPermissions() { PermissionSupport.openSettings() }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    deinit { NotificationCenter.default.removeObserver(self) }
}

/// An illustrative local drawing, not a screenshot of the user's desktop.
final class FocusPreviewView: NSView {
    var intensity: Double = 0.55
    var tint = NSColor.black
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
        let gradient = NSGradient(colors: [NSColor(srgbRed: 0.52, green: 0.49, blue: 0.75, alpha: 1),
                                           NSColor(srgbRed: 0.24, green: 0.28, blue: 0.49, alpha: 1)])!
        gradient.draw(in: bounds, angle: 28)
        let arc = NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.2, y: 72, width: 400, height: 220))
        NSColor.white.withAlphaComponent(0.09).setFill(); arc.fill()
        drawWindow(NSRect(x: 18, y: 20, width: 144, height: 103), active: false)
        drawWindow(NSRect(x: bounds.width - 120, y: 42, width: 150, height: 104), active: false)
        tint.withAlphaComponent(intensity).setFill(); bounds.fill()
        let focused = NSRect(x: bounds.midX - 86, y: 29, width: 172, height: 108)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 13; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
        NSColor(srgbRed: 0.97, green: 0.96, blue: 0.99, alpha: 1).setFill()
        NSBezierPath(roundedRect: focused, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        drawWindow(focused, active: true)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWindow(_ rect: NSRect, active: Bool) {
        let body = active ? NSColor(srgbRed: 0.97, green: 0.96, blue: 0.99, alpha: 1) : NSColor(srgbRed: 0.83, green: 0.83, blue: 0.91, alpha: 1)
        body.setFill(); NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            (active ? color : NSColor.gray.withAlphaComponent(0.45)).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 10 + CGFloat(index) * 9, y: rect.minY + 9, width: 5, height: 5)).fill()
        }
        NSColor.black.withAlphaComponent(0.06).setFill()
        NSRect(x: rect.minX, y: rect.minY + 23, width: rect.width, height: 1).fill()
        if active {
            ("只专注，眼前这一件。" as NSString).draw(at: NSPoint(x: rect.minX + 17, y: rect.minY + 39), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 0.22, green: 0.20, blue: 0.33, alpha: 1)])
        }
        for index in 0..<3 {
            (active ? ShadeUI.accent.withAlphaComponent(index == 0 ? 0.3 : 0.12) : NSColor.gray.withAlphaComponent(0.25)).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 17, y: rect.minY + (active ? 65 : 37) + CGFloat(index) * 10,
                                             width: rect.width - CGFloat(45 + index * 14), height: 4), xRadius: 2, yRadius: 2).fill()
        }
    }
}
