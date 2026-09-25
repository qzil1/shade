import Cocoa

protocol AccessibilityPromptWindowDelegate: AnyObject {
    func accessibilityPromptWindowDidClose()
}

class AccessibilityPromptWindow: NSWindowController {
    weak var delegate: AccessibilityPromptWindowDelegate?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .modalPanel
        window.center()
        super.init(window: window)
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        let container = NSVisualEffectView(frame: contentView.bounds)
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32)
        ])

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64)
        ])
        stack.addArrangedSubview(iconView)

        let title = NSTextField(labelWithString: "需要辅助功能权限")
        title.font = NSFont.boldSystemFont(ofSize: 17)
        title.alignment = .center
        stack.addArrangedSubview(title)

        let desc = NSTextField(wrappingLabelWithString:
            "允许 Shade 识别活动窗口，让背景自然变暗。无需屏幕录制权限，不读取或保存窗口内容。")
        desc.font = NSFont.systemFont(ofSize: 13)
        desc.alignment = .center
        desc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(desc)

        let instruction = NSTextField(wrappingLabelWithString:
            "在系统设置 → 隐私与安全 → 辅助功能中启用 Shade。授权后会自动生效，无需重启。")
        instruction.font = NSFont.systemFont(ofSize: 12)
        instruction.alignment = .center
        instruction.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(instruction)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        stack.addArrangedSubview(buttonRow)

        let openBtn = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        openBtn.bezelStyle = .rounded
        openBtn.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(openBtn)

        let laterBtn = NSButton(title: "以后再说", target: self, action: #selector(closeWindow))
        laterBtn.bezelStyle = .rounded
        buttonRow.addArrangedSubview(laterBtn)
    }

    @objc private func openSettings() {
        PermissionSupport.openSettings()
        closeWindow()
    }

    @objc private func closeWindow() {
        window?.close()
        delegate?.accessibilityPromptWindowDidClose()
    }
}
