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
        // At least one of ⌃⌥⌘. A registered hotkey *consumes* the keystroke
        // system-wide, so "space" or "a" would kill that key in every
        // application for as long as Chestnut runs. Shift doesn't count on
        // its own — "shift+a" is just A — but is fine alongside another.
        guard mods & Self.requiredModifiers != 0 else { return nil }
        keyCode = k
        modifiers = mods
    }

    private static let requiredModifiers = UInt32(controlKey | optionKey | cmdKey)

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

    /// The NSMenuItem representation of the binding. Display-only — the real
    /// hotkey is Carbon-registered — but derived from the *same parse*, so
    /// the menu can never show a key equivalent that no registered hotkey
    /// backs, or hide one that works. (PetWindow used to tokenize the string
    /// itself with its own tables; the grammars drifted — its parser took
    /// "shift+a", which Carbon registration refuses, and rejected "f1",
    /// which it accepts.)
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let key = Self.keyEquivalents[keyCode] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return (key, flags)
    }

    /// keyCode → NSMenuItem `keyEquivalent` string: the reverse of `keyMap`,
    /// built from it so a key can't exist in one direction only.
    private static let keyEquivalents: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        // Letters and digits are their own equivalents.
        for (name, code) in keyMap where name.count == 1 { m[code] = name }
        m[UInt32(kVK_Space)] = " "
        m[UInt32(kVK_Tab)] = "\t"
        m[UInt32(kVK_Return)] = "\r"
        m[UInt32(kVK_Escape)] = "\u{1B}"
        m[UInt32(kVK_Delete)] = "\u{08}"
        // NSMenuItem draws function keys via the Unicode function-key scalars.
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                     kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in fkeys.enumerated() {
            m[UInt32(code)] = String(UnicodeScalar(NSF1FunctionKey + index)!)
        }
        return m
    }()

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
    var onPaste: (() -> Void)?
    var onMenu: (() -> Void)?
    /// The menu binding is the only keyboard route to Settings, Undo, and
    /// Quit — `canBecomeKey` is false so no key equivalent ever fires, and an
    /// LSUIElement app is absent from Force Quit — so its failure can't stay
    /// in a log the way the others' can. Fired at most once per launch, with
    /// the binding string and a human-readable reason. An empty / "none" /
    /// "disabled" binding is a deliberate opt-out and stays silent.
    var onMenuHotkeyFailure: ((_ binding: String, _ reason: String) -> Void)?

    private var registeredKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var noticeSpec: HotkeySpec?
    private var menuSpec: HotkeySpec?
    private var menuBinding = ""
    private var menuFailureReported = false

    private static let signature = OSType(0x4348_4E54)  // "CHNT"
    private static let captureID: UInt32 = 1
    private static let hopperID: UInt32 = 2
    private static let noticeID: UInt32 = 3
    private static let pasteID: UInt32 = 4
    private static let menuID: UInt32 = 5

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
        register(config.paste, id: Self.pasteID, label: "paste")

        menuBinding = config.menu
        menuSpec = HotkeySpec(config.menu)
        register(config.menu, id: Self.menuID, label: "menu")
        if menuSpec == nil, !Self.isOptedOut(config.menu) {
            reportMenuFailure("It isn't a valid hotkey")
        }

        // The notice hotkey is registered on demand — only while an
        // actionable bubble is visible — so Chestnut doesn't consume the
        // combo system-wide around the clock. Parse (and complain) once here.
        noticeSpec = HotkeySpec(config.notice)
        if noticeSpec == nil, !Self.isOptedOut(config.notice) {
            NSLog("HotkeyCenter: invalid notice hotkey \"%@\"", config.notice)
        }
    }

    /// True for the strings that mean "no hotkey, on purpose" — the same set
    /// `HotkeySpec.init` maps to nil deliberately rather than by rejection.
    private static func isOptedOut(_ binding: String) -> Bool {
        let raw = binding.trimmingCharacters(in: .whitespaces).lowercased()
        return raw.isEmpty || raw == "none" || raw == "disabled"
    }

    private func reportMenuFailure(_ reason: String) {
        guard !menuFailureReported else { return }
        menuFailureReported = true
        onMenuHotkeyFailure?(menuBinding, reason)
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

    /// Unregistered for as long as the menu is on screen.
    ///
    /// `RegisterEventHotKey` *consumes* the keystroke, and while a menu tracks,
    /// its nested run loop doesn't dispatch our Carbon handler — so presses are
    /// captured, queued, and delivered the instant tracking ends. Left
    /// registered, pressing the menu hotkey while the menu is open does nothing
    /// visible and then reopens the menu right after Esc dismisses it, once per
    /// press. Giving the key back to the system for the duration is what stops
    /// it being captured at all. Idempotent in both directions.
    func setMenuHotkeyEnabled(_ enabled: Bool) {
        if enabled {
            guard registeredKeys[Self.menuID] == nil, let spec = menuSpec else { return }
            register(spec, id: Self.menuID, label: "menu")
        } else if let ref = registeredKeys.removeValue(forKey: Self.menuID) {
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
            if !Self.isOptedOut(binding) {
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
            DebugLog.log("hotkey: register \(label) FAILED (OSStatus \(status))")
            if id == Self.menuID {
                reportMenuFailure("Another app may already be using it")
            }
        } else if let ref {
            registeredKeys[id] = ref
            DebugLog.log("hotkey: registered \(label) (keyCode=\(spec.keyCode), mods=\(spec.modifiers))")
        }
    }

    private func dispatch(_ id: EventHotKeyID) {
        guard id.signature == Self.signature else { return }
        let label: String
        switch id.id {
        case Self.captureID: label = "capture"; onCapture?()
        case Self.hopperID: label = "hopper"; onHopper?()
        case Self.noticeID: label = "notice"; onNotice?()
        case Self.pasteID: label = "paste"; onPaste?()
        case Self.menuID: label = "menu"; onMenu?()
        default: return
        }
        DebugLog.log("hotkey: dispatched \(label)")
    }
}
