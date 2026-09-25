import Cocoa

extension Notification.Name {
    static let shadeSettingsDidChange = Notification.Name("ShadeSettingsDidChange")
    static let shadeStatusDidChange = Notification.Name("ShadeStatusDidChange")
}

enum ShadeTint: String, CaseIterable {
    case graphite, warm, midnight
    var title: String {
        switch self {
        case .graphite: return "石墨"
        case .warm: return "暖夜"
        case .midnight: return "深蓝"
        }
    }
    var color: NSColor {
        switch self {
        case .graphite: return .black
        case .warm: return NSColor(srgbRed: 0.16, green: 0.09, blue: 0.035, alpha: 1)
        case .midnight: return NSColor(srgbRed: 0.035, green: 0.055, blue: 0.16, alpha: 1)
        }
    }
}

final class ShadeSettings {
    private let defaults: UserDefaults
    var useDarkAppearance = false {
        didSet { if oldValue != useDarkAppearance { notify() } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "enabled": true, "lightIntensity": 0.55, "darkIntensity": 0.40,
            "fadeDuration": 0.18, "pauseWithFn": true,
            "displayMode": DisplayMode.dimOthers.rawValue
        ])
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { set(newValue, for: "enabled") }
    }
    var separateDarkAppearance: Bool {
        get { defaults.bool(forKey: "separateDarkAppearance") }
        set { set(newValue, for: "separateDarkAppearance") }
    }
    private var profile: String { separateDarkAppearance && useDarkAppearance ? "dark" : "light" }
    var intensity: Double {
        get { sanitize(defaults.double(forKey: "\(profile)Intensity"), range: 0...0.9, fallback: 0.55) }
        set { set(sanitize(newValue, range: 0...0.9, fallback: 0.55), for: "\(profile)Intensity") }
    }
    var tint: ShadeTint {
        get { ShadeTint(rawValue: defaults.string(forKey: "\(profile)Tint") ?? "") ?? .graphite }
        set { set(newValue.rawValue, for: "\(profile)Tint") }
    }
    var darkTint: ShadeTint { ShadeTint(rawValue: defaults.string(forKey: "darkTint") ?? "") ?? .graphite }
    var fadeDuration: Double {
        get { sanitize(defaults.double(forKey: "fadeDuration"), range: 0...0.5, fallback: 0.18) }
        set { set(sanitize(newValue, range: 0...0.5, fallback: 0.18), for: "fadeDuration") }
    }
    var pauseWithFn: Bool {
        get { defaults.bool(forKey: "pauseWithFn") }
        set { set(newValue, for: "pauseWithFn") }
    }
    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .dimOthers }
        set { set(newValue.rawValue, for: "displayMode") }
    }
    var excludedApplications: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedApplications") ?? []) }
        set { set(newValue.sorted(), for: "excludedApplications") }
    }
    var excludedDisplays: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedDisplays") ?? []) }
        set { set(newValue.sorted(), for: "excludedDisplays") }
    }

    private func sanitize(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
    private func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        notify()
    }
    private func notify() { NotificationCenter.default.post(name: .shadeSettingsDidChange, object: self) }
}
