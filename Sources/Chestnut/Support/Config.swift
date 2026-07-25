import Foundation

/// Hand-edited settings, stored as JSON in ~/Library/Application Support/Chestnut/.
/// Chestnut's own config only — never anything inside a vault or `.obsidian/`.
///
/// This file belongs to the user. Chestnut writes it exactly twice in its life:
/// once to create it if it's missing, and once to migrate a pre-0.3 config (see
/// `AppState.migrateFromLegacyConfig`). Everything the app changes for itself —
/// window position, size, theme, pinned vault, disabled plugins — lives in
/// `AppState`, so a window drag can never clobber a hand-edited hotkey.
///
/// Changes here take effect on next launch; nothing re-reads the file.
struct Config: Codable, Equatable {
    /// Capture: note at the vault root receiving captures when the daily note
    /// can't be determined. Hand-editable; a bare file name, no folders.
    var captureInboxName = "Inbox.md"
    /// Chestnut-native daily-note format (Moment.js tokens: YYYY, MM, DD, …).
    /// Used when Obsidian's daily-notes plugin is disabled. Nil = no override.
    var captureFormat: String?
    /// Folder for Chestnut-native daily notes (relative to vault root).
    var captureFolder: String?
    /// Custom palette override, hand-editable only (no UI): role char →
    /// "#RRGGBB"/"#RRGGBBAA", applied on top of the theme. Kept verbatim so
    /// saving doesn't rewrite a hand-edited config; entries that don't parse
    /// are ignored per-role at resolve time (SpriteTheme.resolvedPalette).
    var petPalette: [String: String]?
    /// User-defined sprite themes (appear in the right-click Theme menu).
    var customThemes: [CustomThemeConfig]?
    /// How long notice bubbles stay visible (seconds).
    var noticeDuration = 5.0
    /// Global hotkey bindings, hand-editable: "modifier+modifier+key".
    /// Set a binding to "" or "none" to disable it.
    var hotkeys = HotkeyConfig()
    var debug = false

    private enum CodingKeys: String, CodingKey {
        case captureInboxName, captureFormat, captureFolder
        case petPalette, customThemes
        case noticeDuration, hotkeys, debug
    }

    static let defaultInboxName = "Inbox.md"

    init() {}

    /// Tolerant decoding: configs written by older builds lack newer keys.
    /// Keys that moved to `AppState` in 0.3 are ignored if still present.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawInbox = try c.decodeIfPresent(String.self, forKey: .captureInboxName)
            ?? Self.defaultInboxName
        // Hand-edited configs: a path here could climb out of the vault.
        captureInboxName = rawInbox.isEmpty || rawInbox.contains("/")
            ? Self.defaultInboxName : rawInbox
        captureFormat = try c.decodeIfPresent(String.self, forKey: .captureFormat)
        captureFolder = try c.decodeIfPresent(String.self, forKey: .captureFolder)
        petPalette = try c.decodeIfPresent([String: String].self, forKey: .petPalette)
        customThemes = try c.decodeIfPresent([CustomThemeConfig].self, forKey: .customThemes)
        let rawNotice = try c.decodeIfPresent(Double.self, forKey: .noticeDuration) ?? 5.0
        noticeDuration = max(rawNotice, 1.0)
        hotkeys = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkeys) ?? HotkeyConfig()
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(captureInboxName, forKey: .captureInboxName)
        try c.encodeIfPresent(captureFormat, forKey: .captureFormat)
        try c.encodeIfPresent(captureFolder, forKey: .captureFolder)
        try c.encodeIfPresent(petPalette, forKey: .petPalette)
        try c.encodeIfPresent(customThemes, forKey: .customThemes)
        try c.encode(noticeDuration, forKey: .noticeDuration)
        try c.encode(hotkeys, forKey: .hotkeys)
        if debug { try c.encode(true, forKey: .debug) }
    }

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Chestnut/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            // Move the unreadable file aside rather than copy it: defaults are
            // then written to a clean path instead of overwriting JSON the user
            // could have fixed by hand.
            let backup = Self.availableBackupURL(
                base: fileURL.appendingPathExtension("bak"),
                exists: { FileManager.default.fileExists(atPath: $0.path) }
            )
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                NSLog("Config load failed (%@) — original moved to %@",
                      error.localizedDescription, backup.path)
            } catch {
                NSLog("Config load failed and the original could not be moved aside: %@",
                      error.localizedDescription)
            }
            return Config()
        }
    }

    /// First unused backup name (`config.json.bak`, `config.json.bak.1`, …) so
    /// recovering an earlier failure stays possible.
    static func availableBackupURL(base: URL, exists: (URL) -> Bool) -> URL {
        guard exists(base) else { return base }
        for n in 1...99 {
            let candidate = base.appendingPathExtension(String(n))
            if !exists(candidate) { return candidate }
        }
        return base.appendingPathExtension(String(Int(Date().timeIntervalSince1970)))
    }

    /// Writes the defaults so there's a documented file to edit — only when
    /// none exists. Never overwrites: an existing config is the user's.
    func createIfMissing() {
        let url = Self.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("Config create failed: %@", error.localizedDescription)
        }
    }
}

struct CustomThemeConfig: Codable, Equatable {
    /// Unique identifier (must not collide with built-in theme ids).
    var id: String
    /// Display name in the Theme menu.
    var title: String
    /// Shell role colors as "#RRGGBB" or "#RRGGBBAA". Required roles:
    /// s (shell), S (highlight/rivets), d (shadow), m (trim), o (outline).
    /// Shared roles (gem, eyes, tongue, etc.) use built-in defaults but
    /// can be overridden here.
    var palette: [String: String]
}

struct HotkeyConfig: Codable, Equatable {
    var capture = "control+option+space"
    var hopper = "control+option+v"
    var notice = "control+option+o"
    var paste = "control+option+c"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capture = try c.decodeIfPresent(String.self, forKey: .capture) ?? "control+option+space"
        hopper = try c.decodeIfPresent(String.self, forKey: .hopper) ?? "control+option+v"
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? "control+option+o"
        paste = try c.decodeIfPresent(String.self, forKey: .paste) ?? "control+option+c"
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
