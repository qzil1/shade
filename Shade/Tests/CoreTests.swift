import Cocoa

@main
struct CoreTests {
    static var count = 0
    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1
        print("PASS: \(name)")
    }

    static func main() {
        let left = DisplayInfo(id: "left", frame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        let main = DisplayInfo(id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let a = WindowInfo(id: 10, pid: 1, frame: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0)
        let b = WindowInfo(id: 20, pid: 2, frame: CGRect(x: -1200, y: 100, width: 800, height: 600), layer: 0)
        let twin = WindowInfo(id: 11, pid: 1, frame: a.frame, layer: 0)
        check("matching uses front-to-back order for identical bounds", WindowSelection.match(pid: 1, frame: a.frame, windows: [twin, a])?.id == 11)
        check("matching never selects another process", WindowSelection.match(pid: 3, frame: a.frame, windows: [a]) == nil)
        check("matching rejects a stale AX frame", WindowSelection.match(pid: 1, frame: b.frame, windows: [a]) == nil)
        let noise = WindowInfo(id: 12, pid: 1, frame: a.frame, layer: 24)
        check("matching excludes menu level windows", WindowSelection.match(pid: 1, frame: a.frame, windows: [noise, a])?.id == 10)
        check("invalid dimensions are rejected", !WindowInfo(id: 13, pid: 1, frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100), layer: 0).isEligible)
        check("coordinates convert above the primary display", DisplayInfo.axFrame(appKitFrame: CGRect(x: 0, y: 900, width: 1200, height: 800), primaryTop: 900).minY == -800)

        func targets(_ mode: DisplayMode, active: WindowInfo? = a, excluded: Set<String> = []) -> [String: DimmingPlacement] {
            DimmingPolicy.placements(displays: [left, main], windows: [a, b], active: active, mode: mode, excludedDisplays: excluded)
        }
        check("active screen orders below the focused window", targets(.dimOthers)["main"] == .below(10))
        check("inactive screen dims all ordinary windows", targets(.dimOthers)["left"] == .above(10))
        check("active-only leaves other screens clear", targets(.activeOnly)["left"] == .hidden)
        check("each-screen preserves that screen's front window", targets(.eachDisplay)["left"] == .below(20))
        check("excluded display is always clear", targets(.dimOthers, excluded: ["main"])["main"] == .hidden)
        check("no active window clears every screen", targets(.dimOthers, active: nil).values.allSatisfy { $0 == .hidden })
        let spanning = WindowInfo(id: 30, pid: 1, frame: CGRect(x: -10, y: 100, width: 810, height: 600), layer: 0)
        check("even a narrow cross-screen slice stays unobscured", targets(.dimOthers, active: spanning)["left"] == .below(30))

        let moved = WindowInfo(id: 10, pid: 1, frame: b.frame, layer: 0)
        check("a known focused window survives asynchronous geometry", WindowSelection.resolve(pid: 1, frame: a.frame, knownWindowID: 10, windows: [moved])?.id == 10)
        check("a vanished identity cannot switch to a same-frame twin", WindowSelection.resolve(pid: 1, frame: a.frame, knownWindowID: 10, windows: [twin]) == nil)
        let domain = "ShadeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = ShadeSettings(defaults: defaults)
        check("fresh settings enable dimming", settings.isEnabled)
        settings.isEnabled = false
        settings.intensity = 0.72
        settings.displayMode = .eachDisplay
        settings.excludedApplications = ["com.apple.Terminal"]
        let restored = ShadeSettings(defaults: defaults)
        check("enabled preference survives restart", !restored.isEnabled)
        check("intensity survives restart", restored.intensity == 0.72)
        check("display mode survives restart", restored.displayMode == .eachDisplay)
        check("exclusions survive restart", restored.excludedApplications.contains("com.apple.Terminal"))
        settings.intensity = 3
        check("intensity clamps before persistence", settings.intensity == 0.9)
        settings.fadeDuration = -.infinity
        check("nonfinite durations are sanitized", settings.fadeDuration.isFinite && settings.fadeDuration >= 0)
        settings.separateDarkAppearance = true
        settings.useDarkAppearance = true
        settings.intensity = 0.35
        settings.useDarkAppearance = false
        check("appearance profiles remain independent", settings.intensity == 0.9)
        settings.useDarkAppearance = true
        check("dark profile is restored", settings.intensity == 0.35)
        settings.tint = .warm
        check("profile tint persists", ShadeSettings(defaults: defaults).darkTint == .warm)
        print("\(count) checks passed")
    }
}
