import Cocoa
import Carbon

class HotKeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []

    var onToggleDimming: (() -> Void)?
    var onDecreaseAlpha: (() -> Void)?
    var onIncreaseAlpha: (() -> Void)?
    var onToggleMultiDisplay: (() -> Void)?

    @discardableResult
    func register() -> [String] {
        unregister()
        var failures: [String] = []
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userInfo -> OSStatus in
            guard let userInfo = userInfo else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()

            var hkID = EventHotKeyID()
            let result = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard result == noErr else { return result }

            manager.handleHotKey(id: hkID.id)
            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard handlerStatus == noErr else { return ["全局快捷键监听"] }
        for (key, id, label) in [(kVK_ANSI_H, 1, "⇧⌘H"), (kVK_DownArrow, 2, "⇧⌘↓"),
                                 (kVK_UpArrow, 3, "⇧⌘↑"), (kVK_ANSI_M, 4, "⇧⌘M")] {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: fourCharCode(from: "HZOV"), id: UInt32(id))
            let status = RegisterEventHotKey(UInt32(key), UInt32(cmdKey | shiftKey), hotKeyID,
                                            GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref = ref { hotKeyRefs.append(ref) }
            else { failures.append(label) }
        }
        return failures
    }

    private func handleHotKey(id: UInt32) {
        switch id {
        case 1: onToggleDimming?()
        case 2: onDecreaseAlpha?()
        case 3: onIncreaseAlpha?()
        case 4: onToggleMultiDisplay?()
        default: break
        }
    }

    func unregister() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    deinit {
        unregister()
    }

    private func fourCharCode(from string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}
