import Cocoa

struct WindowInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect // AX / Quartz global coordinates: top-left of the primary display.
    let layer: Int

    var isEligible: Bool {
        id != 0 && pid > 0 && (0...3).contains(layer) &&
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.width.isFinite && frame.height.isFinite && frame.width > 40 && frame.height > 40
    }

    init(id: CGWindowID, pid: pid_t, frame: CGRect, layer: Int) {
        self.id = id; self.pid = pid; self.frame = frame; self.layer = layer
    }

    init?(dictionary: [String: Any]) {
        guard let id = dictionary[kCGWindowNumber as String] as? UInt32,
              let pid = dictionary[kCGWindowOwnerPID as String] as? Int32,
              let bounds = dictionary[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              let layer = dictionary[kCGWindowLayer as String] as? Int,
              (dictionary[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
        self.init(id: id, pid: pid, frame: frame, layer: layer)
        if !isEligible { return nil }
    }
}

struct DisplayInfo {
    let id: String
    let frame: CGRect

    static func axFrame(appKitFrame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: appKitFrame.minX, y: primaryTop - appKitFrame.maxY,
               width: appKitFrame.width, height: appKitFrame.height)
    }
}

enum DisplayMode: String, CaseIterable {
    case dimOthers, eachDisplay, activeOnly

    var title: String {
        switch self {
        case .dimOthers: return "仅突出当前窗口"
        case .eachDisplay: return "每个显示器保留一个窗口"
        case .activeOnly: return "只调暗当前显示器"
        }
    }

    var detail: String {
        switch self {
        case .dimOthers: return "其他显示器也会柔和变暗，始终知道焦点在哪里。"
        case .eachDisplay: return "各个屏幕保留最前方的窗口，方便同时参考。"
        case .activeOnly: return "其他屏幕保持原样，适合视频或参考资料。"
        }
    }
}

enum DimmingPlacement: Equatable {
    case hidden
    case below(CGWindowID)
    case above(CGWindowID)

    var isBelow: Bool { if case .below = self { return true }; return false }

    var windowID: CGWindowID? {
        switch self {
        case .hidden: return nil
        case .below(let id), .above(let id): return id
        }
    }
}

enum WindowSelection {
    static func resolve(pid: pid_t, frame: CGRect?, knownWindowID: CGWindowID?, windows: [WindowInfo]) -> WindowInfo? {
        if let id = knownWindowID { return windows.first { $0.id == id && $0.pid == pid && $0.isEligible } }
        return frame.flatMap { match(pid: pid, frame: $0, windows: windows) }
    }

    static func match(pid: pid_t, frame: CGRect, windows: [WindowInfo]) -> WindowInfo? {
        // The list is front-to-back. Identical frames belong to different windows;
        // never use geometry alone as the identity or fall back to an arbitrary app.
        windows.first {
            $0.pid == pid && $0.isEligible &&
            abs($0.frame.minX - frame.minX) <= 3 && abs($0.frame.minY - frame.minY) <= 3 &&
            abs($0.frame.width - frame.width) <= 3 && abs($0.frame.height - frame.height) <= 3
        }
    }
}

enum DimmingPolicy {
    static func placements(displays: [DisplayInfo], windows: [WindowInfo], active: WindowInfo?,
                           mode: DisplayMode, excludedDisplays: Set<String>) -> [String: DimmingPlacement] {
        var result: [String: DimmingPlacement] = [:]
        for display in displays {
            guard let active = active, active.isEligible, !excludedDisplays.contains(display.id) else {
                result[display.id] = .hidden
                continue
            }
            let intersection = active.frame.intersection(display.frame)
            if !intersection.isNull && !intersection.isEmpty {
                // Do not clip or round the intersection: WindowServer draws the real
                // window across displays, including one-pixel slivers and its shadow.
                result[display.id] = .below(active.id)
            } else {
                switch mode {
                case .dimOthers: result[display.id] = .above(active.id)
                case .activeOnly: result[display.id] = .hidden
                case .eachDisplay:
                    let front = windows.first {
                        $0.isEligible && $0.layer == 0 &&
                        $0.frame.intersection(display.frame).width > 40 &&
                        $0.frame.intersection(display.frame).height > 40
                    }
                    result[display.id] = front.map { .below($0.id) } ?? .hidden
                }
            }
        }
        return result
    }
}
