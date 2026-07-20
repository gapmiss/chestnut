import AppKit
import Carbon.HIToolbox

/// A parsed global-hotkey binding: keyCode + Carbon modifier mask.
struct HotkeySpec {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Parse "modifier+modifier+key" (e.g. "control+option+space", "cmd+shift+k").
    /// Returns nil for empty / "none" / "disabled" / malformed strings.
    init?(_ string: String) {
        let raw = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty, raw != "none", raw != "disabled" else { return nil }

        let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var mods: UInt32 = 0
        var key: UInt32?

        for part in parts {
            if let m = Self.modifierMap[part] {
                mods |= m
            } else if let k = Self.keyMap[part] {
                if key != nil { return nil }
                key = k
            } else {
                return nil
            }
        }

        guard let k = key else { return nil }
        keyCode = k
        modifiers = mods
    }

    /// "control+option+o" → "⌃⌥O", for UI hints. Nil when the binding is
    /// empty, disabled, or malformed. Modifiers render in the macOS
    /// convention order ⌃⌥⇧⌘ regardless of how the string spells them.
    static func display(_ string: String) -> String? {
        guard Self(string) != nil else { return nil }
        let parts = string.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let order: [(names: Set<String>, symbol: String)] = [
            (["control", "ctrl"], "⌃"), (["option", "alt"], "⌥"),
            (["shift"], "⇧"), (["command", "cmd"], "⌘"),
        ]
        var out = ""
        for (names, symbol) in order where parts.contains(where: names.contains) {
            out += symbol
        }
        for part in parts where modifierMap[part] == nil {
            out += keyLabels[part] ?? part.uppercased()
        }
        return out
    }

    private static let keyLabels: [String: String] = [
        "space": "Space", "tab": "⇥", "return": "↩", "enter": "↩",
        "escape": "⎋", "esc": "⎋", "delete": "⌫", "backspace": "⌫",
    ]

    private static let modifierMap: [String: UInt32] = [
        "control": UInt32(controlKey),
        "ctrl": UInt32(controlKey),
        "option": UInt32(optionKey),
        "alt": UInt32(optionKey),
        "command": UInt32(cmdKey),
        "cmd": UInt32(cmdKey),
        "shift": UInt32(shiftKey),
    ]

    private static let keyMap: [String: UInt32] = {
        var m: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B),
            "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
            "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
            "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J),
            "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N),
            "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
            "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
            "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V),
            "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1),
            "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
            "space": UInt32(kVK_Space),
            "tab": UInt32(kVK_Tab),
            "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
            "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
            "delete": UInt32(kVK_Delete), "backspace": UInt32(kVK_Delete),
        ]
        let fkeys: [(String, Int)] = [
            ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
            ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8),
            ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
        ]
        for (name, code) in fkeys { m[name] = UInt32(code) }
        return m
    }()
}

/// Global hotkeys via Carbon's RegisterEventHotKey: unlike an NSEvent global
/// monitor it needs no accessibility permission and consumes the keystroke.
/// The Carbon dispatcher delivers hotkey events on the main thread.
@MainActor
final class HotkeyCenter {
    var onCapture: (() -> Void)?
    var onHopper: (() -> Void)?
    var onNotice: (() -> Void)?

    private var registeredKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var noticeSpec: HotkeySpec?

    private static let signature = OSType(0x4348_4E54)  // "CHNT"
    private static let captureID: UInt32 = 1
    private static let hopperID: UInt32 = 2
    private static let noticeID: UInt32 = 3

    func start(config: HotkeyConfig) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    center.dispatch(hotKeyID)
                }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        register(config.capture, id: Self.captureID, label: "capture")
        register(config.hopper, id: Self.hopperID, label: "hopper")

        // The notice hotkey is registered on demand — only while an
        // actionable bubble is visible — so Chestnut doesn't consume the
        // combo system-wide around the clock. Parse (and complain) once here.
        noticeSpec = HotkeySpec(config.notice)
        if noticeSpec == nil, !config.notice.isEmpty,
           config.notice.lowercased() != "none",
           config.notice.lowercased() != "disabled" {
            NSLog("HotkeyCenter: invalid notice hotkey \"%@\"", config.notice)
        }
    }

    /// Register/unregister the notice hotkey as the actionable bubble
    /// appears and goes away. Idempotent in both directions.
    func setNoticeHotkeyEnabled(_ enabled: Bool) {
        if enabled {
            guard registeredKeys[Self.noticeID] == nil, let spec = noticeSpec else { return }
            register(spec, id: Self.noticeID, label: "notice")
        } else if let ref = registeredKeys.removeValue(forKey: Self.noticeID) {
            UnregisterEventHotKey(ref)
        }
    }

    func stop() {
        for (_, ref) in registeredKeys { UnregisterEventHotKey(ref) }
        registeredKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func register(_ binding: String, id: UInt32, label: String) {
        guard let spec = HotkeySpec(binding) else {
            if !binding.isEmpty, binding.lowercased() != "none",
               binding.lowercased() != "disabled" {
                NSLog("HotkeyCenter: invalid %@ hotkey \"%@\"", label, binding)
            }
            return
        }
        register(spec, id: id, label: label)
    }

    private func register(_ spec: HotkeySpec, id: UInt32, label: String) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers,
            hotKeyID, GetEventDispatcherTarget(), 0, &ref
        )
        if status != noErr {
            NSLog("HotkeyCenter: could not register %@ hotkey (OSStatus %d)", label, status)
        } else if let ref {
            registeredKeys[id] = ref
        }
    }

    private func dispatch(_ id: EventHotKeyID) {
        guard id.signature == Self.signature else { return }
        switch id.id {
        case Self.captureID: onCapture?()
        case Self.hopperID: onHopper?()
        case Self.noticeID: onNotice?()
        default: break
        }
    }
}
