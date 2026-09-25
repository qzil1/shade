import Cocoa
import ServiceManagement

// Permission state is runtime state; it must not overwrite the saved on/off setting.
enum PermissionSupport {
    static func openSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LoginSupport {
    static var available: Bool {
        if #available(macOS 13.0, *) { return Bundle.main.bundleURL.pathExtension == "app" }
        return false
    }
    static var enabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
        return false
    }
    static var detail: String {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .requiresApproval { return "请在系统设置 → 通用 → 登录项中允许 Shade。" }
            return "登录后自动进入专注状态。建议将 Shade 放入“应用程序”。"
        }
        return "macOS 11–12 请在系统偏好设置的登录项中添加 Shade。"
    }
    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
    }
}
