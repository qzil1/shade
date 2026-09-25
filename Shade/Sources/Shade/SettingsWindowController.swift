import Cocoa
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    private let controller: SettingsViewController
    init(manager: OverlayManager) {
        controller = SettingsViewController(manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 652, height: 552),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Shade 设置"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrameAutosaveName("ShadeSettingsWindow")
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        controller.captureCurrentApplication()
        controller.reloadPage()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class ActionButton: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self; action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { perform?() }
}

final class SettingsViewController: NSViewController {
    private let manager: OverlayManager
    private let tabs = NSSegmentedControl(labels: ["通用", "显示器", "应用排除", "快捷控制"], trackingMode: .selectOne, target: nil, action: nil)
    private let page = NSView()
    private var capturedApplication: (id: String, name: String)?
    private var durationLabel: NSTextField?
    private var screenObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    init(manager: OverlayManager) { self.manager = manager; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 652, height: 552))
        let title = ShadeUI.label("更适合你的专注方式", size: 23, weight: .semibold)
        let subtitle = ShadeUI.label("安静地融入桌面，清晰地留住注意力。", size: 12, color: .secondaryLabelColor)
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = 0
        tabs.target = self; tabs.action = #selector(tabChanged)
        let footer = ShadeUI.row(ShadeUI.label("SHADE  /  1.1", size: 10, weight: .medium, color: .tertiaryLabelColor),
                                 ShadeUI.label("本地运行 · 无需账户", size: 10, color: .tertiaryLabelColor))
        let root = ShadeUI.stack([title, subtitle, tabs, page, ShadeUI.separator(), footer], spacing: 16)
        ShadeUI.pin(root, in: view, inset: 28)
        ShadeUI.stretch([tabs, page, footer], in: root)
        page.setContentHuggingPriority(.defaultLow, for: .vertical)
        page.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.tabs.selectedSegment == 1 { self?.reloadPage() }
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: .shadeSettingsDidChange, object: manager.settings, queue: .main) { [weak self] _ in
            if self?.tabs.selectedSegment == 1 { self?.reloadPage() }
        }
        reloadPage()
    }

    func captureCurrentApplication() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier, let id = app.bundleIdentifier {
            capturedApplication = (id, app.localizedName ?? id)
        }
    }
    @objc private func tabChanged() { reloadPage() }
    func reloadPage() {
        guard isViewLoaded else { return }
        page.subviews.forEach { $0.removeFromSuperview() }
        durationLabel = nil
        let content: NSStackView
        switch tabs.selectedSegment {
        case 1: content = displaysPage()
        case 2: content = applicationsPage()
        case 3: content = shortcutsPage()
        default: content = generalPage()
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor)
        ])
        ShadeUI.stretch(content.arrangedSubviews, in: content)
    }

    private func toggleRow(_ title: String, detail: String, value: Bool, tag: Int, enabled: Bool = true) -> NSView {
        let control = NSSwitch()
        control.state = value ? .on : .off
        control.isEnabled = enabled
        control.tag = tag; control.target = self; control.action = #selector(toggleChanged(_:))
        control.setAccessibilityLabel(title)
        let labels = ShadeUI.stack([ShadeUI.label(title, weight: .medium), ShadeUI.detail(detail)], spacing: 4)
        labels.widthAnchor.constraint(lessThanOrEqualToConstant: 490).isActive = true
        return ShadeUI.row(labels, control)
    }

    private func generalPage() -> NSStackView {
        let settings = manager.settings
        let login = toggleRow("登录时启动", detail: LoginSupport.detail, value: LoginSupport.enabled, tag: 2, enabled: LoginSupport.available)
        let dark = toggleRow("为深色外观单独保存色调和强度", detail: "跟随 macOS 外观切换；在菜单栏面板调整当前外观的效果。", value: settings.separateDarkAppearance, tag: 0)
        let fn = toggleRow("按住 Fn 临时暂停", detail: "跨窗口拖放文件时，松开按键即可恢复调光。", value: settings.pauseWithFn, tag: 1)
        let amount = ShadeUI.label(durationText, size: 12, weight: .medium, color: ShadeUI.accent)
        durationLabel = amount
        let slider = NSSlider(value: settings.fadeDuration, minValue: 0, maxValue: 0.5, target: self, action: #selector(durationChanged(_:)))
        slider.isContinuous = true
        slider.setAccessibilityLabel("调光渐变时长")
        let row = ShadeUI.row(ShadeUI.label("渐变时长", weight: .medium), amount)
        let fade = ShadeUI.stack([row, slider, ShadeUI.detail("用于启用、暂停与强度变化。焦点和窗口移动即时跟随；遵循系统“减少动态效果”。")], spacing: 7)
        ShadeUI.stretch(fade.arrangedSubviews, in: fade)
        let permission = ActionButton(manager.watcher.hasPermission ? "检查辅助功能设置…" : "开启辅助功能权限…") { PermissionSupport.openSettings() }
        return ShadeUI.stack([login, dark, fn, ShadeUI.separator(), fade, permission], spacing: 19)
    }
    private var durationText: String {
        manager.settings.fadeDuration == 0 ? "即时" : "\(Int(manager.settings.fadeDuration * 1000)) ms"
    }
    @objc private func durationChanged(_ sender: NSSlider) {
        manager.settings.fadeDuration = sender.doubleValue
        durationLabel?.stringValue = durationText
    }
    @objc private func toggleChanged(_ sender: NSSwitch) {
        switch sender.tag {
        case 0: manager.settings.separateDarkAppearance = sender.state == .on
        case 1: manager.settings.pauseWithFn = sender.state == .on
        case 2:
            do { try LoginSupport.setEnabled(sender.state == .on) }
            catch {
                sender.state = LoginSupport.enabled ? .on : .off
                let alert = NSAlert()
                alert.messageText = "无法更改登录项"
                alert.informativeText = error.localizedDescription
                if let window = view.window { alert.beginSheetModal(for: window) }
            }
        default: break
        }
    }

    private func displaysPage() -> NSStackView {
        let picker = NSPopUpButton()
        picker.addItems(withTitles: DisplayMode.allCases.map(\.title))
        picker.selectItem(at: DisplayMode.allCases.firstIndex(of: manager.settings.displayMode) ?? 0)
        picker.target = self; picker.action = #selector(displayModeChanged(_:))
        picker.setAccessibilityLabel("多显示器调光方式")
        var rows: [NSView] = [ShadeUI.label("多屏幕，保持从容", size: 16, weight: .semibold), picker,
                              ShadeUI.detail(manager.settings.displayMode.detail), ShadeUI.separator()]
        for overlay in manager.windows {
            let enabled = !manager.settings.excludedDisplays.contains(overlay.displayID)
            let check = NSButton(checkboxWithTitle: overlay.targetScreen.localizedName, target: self, action: #selector(displayChanged(_:)))
            check.state = enabled ? .on : .off
            check.identifier = NSUserInterfaceItemIdentifier(overlay.displayID)
            let frame = overlay.targetScreen.frame
            rows.append(ShadeUI.row(check, ShadeUI.label("\(Int(frame.width)) × \(Int(frame.height))", size: 11, color: .secondaryLabelColor)))
        }
        rows.append(ShadeUI.detail("取消勾选的显示器始终保持原样。连接状态变化后会自动更新。"))
        return ShadeUI.stack(rows, spacing: 18)
    }
    @objc private func displayModeChanged(_ sender: NSPopUpButton) {
        manager.settings.displayMode = DisplayMode.allCases[sender.indexOfSelectedItem]
        reloadPage()
    }
    @objc private func displayChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var excluded = manager.settings.excludedDisplays
        if sender.state == .on { excluded.remove(id) } else { excluded.insert(id) }
        manager.settings.excludedDisplays = excluded
    }

    private func applicationsPage() -> NSStackView {
        let add = ActionButton("添加应用…") { [weak self] in self?.chooseApplication() }
        var buttons: [NSView] = [add]
        if let app = capturedApplication {
            buttons.append(ActionButton("添加 \(app.name)") { [weak self] in self?.addApplication(app.id) })
        }
        let controls = ShadeUI.stack(buttons, vertical: false)
        let items = ShadeUI.stack([], spacing: 10)
        for id in manager.settings.excludedApplications.sorted() {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
            let remove = ActionButton("移除") { [weak self] in
                self?.manager.settings.excludedApplications.remove(id)
                self?.reloadPage()
            }
            remove.toolTip = "移除 \(name)"
            let text = ShadeUI.stack([ShadeUI.label(name, weight: .medium), ShadeUI.label(id, size: 10, color: .secondaryLabelColor)], spacing: 3)
            items.addArrangedSubview(ShadeUI.row(text, remove))
        }
        if items.arrangedSubviews.isEmpty {
            items.addArrangedSubview(ShadeUI.detail("暂无排除应用。\n\n绘图、剪辑或演示时需要完整桌面？把应用加到这里。"))
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = items
        items.translatesAutoresizingMaskIntoConstraints = false
        items.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        items.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        items.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        ShadeUI.stretch(items.arrangedSubviews, in: items)
        scroll.heightAnchor.constraint(equalToConstant: 205).isActive = true
        return ShadeUI.stack([ShadeUI.label("有些时刻，需要全景", size: 16, weight: .semibold),
                              ShadeUI.detail("这些应用位于前台时，Shade 自动暂停；切走后恢复。"), controls, scroll], spacing: 16)
    }
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加应用"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            self?.addApplication(id)
        }
    }
    private func addApplication(_ id: String) {
        manager.settings.excludedApplications.insert(id)
        reloadPage()
    }

    private func shortcutsPage() -> NSStackView {
        let shortcuts = [("启用 / 暂停调光", "⇧⌘H"), ("增强背景变暗", "⇧⌘↑"),
                         ("减弱背景变暗", "⇧⌘↓"), ("切换多屏策略", "⇧⌘M")]
        var rows: [NSView] = [ShadeUI.label("不用离开手上的事", size: 16, weight: .semibold)]
        for (title, keys) in shortcuts {
            rows.append(ShadeUI.row(ShadeUI.label(title), ShadeUI.label(keys, size: 14, weight: .medium, color: ShadeUI.accent)))
        }
        rows += [ShadeUI.separator(), ShadeUI.detail("双击菜单栏图标开关调光。\n在图标上滚动调整强度，右键打开快捷菜单。\n按住 Fn 临时暂停，松开恢复（可在通用设置关闭）。")]
        if let warning = manager.shortcutWarning {
            let label = ShadeUI.detail(warning + "。请更改其他应用的冲突绑定后重新启动 Shade。")
            label.textColor = .systemOrange
            rows.append(label)
        }
        return ShadeUI.stack(rows, spacing: 19)
    }
    deinit {
        if let token = screenObserver { NotificationCenter.default.removeObserver(token) }
        if let token = settingsObserver { NotificationCenter.default.removeObserver(token) }
    }
}
