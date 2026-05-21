import Cocoa

class PreferencesViewController: NSViewController {
    private let overlayManager: OverlayManager
    private var displayToggle: NSSwitch?

    init(overlayManager: OverlayManager) {
        self.overlayManager = overlayManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 225))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])

        // Toggle row
        let toggleRow = NSStackView()
        toggleRow.orientation = .horizontal
        toggleRow.distribution = .fill

        let toggleLabel = NSTextField(labelWithString: "启用遮罩")
        toggleLabel.font = NSFont.systemFont(ofSize: 13)

        let toggle = NSSwitch()
        toggle.state = overlayManager.isEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))

        toggleRow.addArrangedSubview(toggleLabel)
        toggleRow.addArrangedSubview(toggle)
        stack.addArrangedSubview(toggleRow)

        // Dim additional displays toggle
        let displayToggleRow = NSStackView()
        displayToggleRow.orientation = .horizontal
        displayToggleRow.distribution = .fill

        let displayToggleLabel = NSTextField(labelWithString: "遮罩附加显示器")
        displayToggleLabel.font = NSFont.systemFont(ofSize: 13)

        let displayToggleSwitch = NSSwitch()
        displayToggleSwitch.state = overlayManager.dimAdditionalDisplays ? .on : .off
        displayToggleSwitch.target = self
        displayToggleSwitch.action = #selector(displayToggleChanged(_:))

        displayToggleRow.addArrangedSubview(displayToggleLabel)
        displayToggleRow.addArrangedSubview(displayToggleSwitch)
        stack.addArrangedSubview(displayToggleRow)
        self.displayToggle = displayToggleSwitch

        // Alpha slider
        let alphaLabel = NSTextField(labelWithString: "遮罩强度")
        alphaLabel.font = NSFont.systemFont(ofSize: 13)
        stack.addArrangedSubview(alphaLabel)

        let slider = NSSlider(value: Double(overlayManager.dimmingAlpha),
                              minValue: 0.1, maxValue: 0.9,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.controlSize = .small
        stack.addArrangedSubview(slider)

        // Animation speed slider
        let speedLabel = NSTextField(labelWithString: "动画速度")
        speedLabel.font = NSFont.systemFont(ofSize: 13)
        stack.addArrangedSubview(speedLabel)

        let speedSlider = NSSlider(value: 1.0 / overlayManager.animationDuration,
                                   minValue: 1.0 / OverlayDefaults.slowAnimationDuration,
                                   maxValue: 1.0 / OverlayDefaults.fastAnimationDuration,
                                   target: self, action: #selector(speedSliderChanged(_:)))
        speedSlider.controlSize = .small
        stack.addArrangedSubview(speedSlider)

        // Speed hint row
        let speedHintRow = NSStackView()
        speedHintRow.orientation = .horizontal
        speedHintRow.distribution = .fillEqually

        let slowLabel = NSTextField(labelWithString: "慢")
        slowLabel.font = NSFont.systemFont(ofSize: 11)
        slowLabel.alignment = .left

        let fastLabel = NSTextField(labelWithString: "快")
        fastLabel.font = NSFont.systemFont(ofSize: 11)
        fastLabel.alignment = .right

        speedHintRow.addArrangedSubview(slowLabel)
        speedHintRow.addArrangedSubview(fastLabel)
        stack.addArrangedSubview(speedHintRow)

        // Spacer pushes the button area to the bottom
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)

        // Visual separator
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)

        // Quit button — full-width action style
        let quitBtn = NSButton(title: "退出 Shade", target: self, action: #selector(quit))
        quitBtn.bezelStyle = .regularSquare
        quitBtn.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        stack.addArrangedSubview(quitBtn)
    }

    func refreshFromManager() {
        displayToggle?.state = overlayManager.dimAdditionalDisplays ? .on : .off
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        overlayManager.isEnabled = (sender.state == .on)
    }

    @objc private func displayToggleChanged(_ sender: NSSwitch) {
        overlayManager.dimAdditionalDisplays = (sender.state == .on)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        overlayManager.dimmingAlpha = CGFloat(sender.doubleValue)
    }

    @objc private func speedSliderChanged(_ sender: NSSlider) {
        // Slider value represents speed (1/duration), so invert to get duration
        let duration = 1.0 / sender.doubleValue
        overlayManager.animationDuration = duration
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
