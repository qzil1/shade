import Cocoa
import Carbon

class HotKeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []

    var onToggleDimming: (() -> Void)?
    var onDecreaseAlpha: (() -> Void)?
    var onIncreaseAlpha: (() -> Void)?
    var onToggleMultiDisplay: (() -> Void)?

    func register() {
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

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        registerHotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey), id: 1)
        registerHotKey(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(cmdKey | shiftKey), id: 2)
        registerHotKey(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(cmdKey | shiftKey), id: 3)
        registerHotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey), id: 4)
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let signature = fourCharCode(from: "HZOV")
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status == noErr, let ref = hotKeyRef {
            hotKeyRefs.append(ref)
        }
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
