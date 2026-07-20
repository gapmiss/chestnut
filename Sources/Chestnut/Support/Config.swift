import Foundation

/// App settings, stored as JSON in ~/Library/Application Support/Chestnut/.
/// Chestnut's own config only — never anything inside a vault or `.obsidian/`.
struct Config: Codable, Equatable {
    enum PetSize: String, Codable, CaseIterable {
        case small, medium, large

        var pixelScale: CGFloat {
            switch self {
            case .small: 4
            case .medium: 6
            case .large: 8
            }
        }

        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }
    }

    /// Window origin (screen coordinates); nil = default bottom-right.
    var position: CGPoint?
    var size: PetSize = .medium
    /// Courier: drops copy instead of move by default (⌥ flips either way).
    var courierCopyByDefault = false
    /// Pet window opacity; the floor keeps the pet findable.
    var opacity = 1.0
    /// Capture: vault that last received a quick capture (keyed by path).
    var lastCaptureVaultPath: String?
    /// User-pinned "home" vault (keyed by path): sorts first in the vault
    /// palettes and wins the capture default over lastCaptureVaultPath.
    var pinnedVaultPath: String?
    /// Capture: note at the vault root receiving captures when the daily note
    /// can't be determined. Hand-editable; a bare file name, no folders.
    var captureInboxName = "Inbox.md"
    /// Chestnut-native daily-note format (Moment.js tokens: YYYY, MM, DD, …).
    /// Used when Obsidian's daily-notes plugin is disabled. Nil = no override.
    var captureFormat: String?
    /// Folder for Chestnut-native daily notes (relative to vault root).
    var captureFolder: String?
    /// Sprite theme id (see SpriteTheme.all).
    var petTheme = SpriteTheme.defaultID
    /// Custom palette override, hand-editable only (no UI): role char →
    /// "#RRGGBB"/"#RRGGBBAA", applied on top of the theme. Kept verbatim so
    /// saving doesn't rewrite a hand-edited config; entries that don't parse
    /// are ignored per-role at resolve time (SpriteTheme.resolvedPalette).
    var petPalette: [String: String]?
    /// User-defined sprite themes (appear in the right-click Theme menu).
    var customThemes: [CustomThemeConfig]?
    /// Show the pet window over full-screen apps.
    var showInFullScreen = true
    /// Global hotkey bindings, hand-editable: "modifier+modifier+key".
    /// Set a binding to "" or "none" to disable it.
    var hotkeys = HotkeyConfig()

    static let opacityRange = 0.1...1.0
    static let defaultInboxName = "Inbox.md"

    init() {}

    /// Tolerant decoding: configs written by older builds lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position)
        size = try c.decodeIfPresent(PetSize.self, forKey: .size) ?? .medium
        courierCopyByDefault =
            try c.decodeIfPresent(Bool.self, forKey: .courierCopyByDefault) ?? false
        let rawOpacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        opacity = rawOpacity.clamped(to: Self.opacityRange)  // hand-edited configs
        lastCaptureVaultPath = try c.decodeIfPresent(String.self, forKey: .lastCaptureVaultPath)
        pinnedVaultPath = try c.decodeIfPresent(String.self, forKey: .pinnedVaultPath)
        let rawInbox = try c.decodeIfPresent(String.self, forKey: .captureInboxName)
            ?? Self.defaultInboxName
        // Hand-edited configs: a path here could climb out of the vault.
        captureInboxName = rawInbox.isEmpty || rawInbox.contains("/")
            ? Self.defaultInboxName : rawInbox
        captureFormat = try c.decodeIfPresent(String.self, forKey: .captureFormat)
        captureFolder = try c.decodeIfPresent(String.self, forKey: .captureFolder)
        petPalette = try c.decodeIfPresent([String: String].self, forKey: .petPalette)
        customThemes = try c.decodeIfPresent([CustomThemeConfig].self, forKey: .customThemes)
        // Theme id validation is deferred: custom themes aren't registered yet
        // at decode time, so accept any non-empty id here. AppDelegate validates
        // after registerCustomThemes.
        petTheme = try c.decodeIfPresent(String.self, forKey: .petTheme)
            ?? SpriteTheme.defaultID
        showInFullScreen =
            try c.decodeIfPresent(Bool.self, forKey: .showInFullScreen) ?? true
        hotkeys = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkeys) ?? HotkeyConfig()
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
            // A hand-edited config with a typo must survive: routine saves
            // (window drags, size changes) would overwrite it with defaults,
            // losing UI-less fields like customThemes and petPalette. Park
            // the unparseable original next door before that can happen.
            let backup = fileURL.appendingPathExtension("bak")
            try? data.write(to: backup, options: .atomic)
            NSLog("Config load failed (%@) — original preserved at %@",
                  error.localizedDescription, backup.path)
            return Config()
        }
    }

    func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("Config save failed: %@", error.localizedDescription)
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capture = try c.decodeIfPresent(String.self, forKey: .capture) ?? "control+option+space"
        hopper = try c.decodeIfPresent(String.self, forKey: .hopper) ?? "control+option+v"
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? "control+option+o"
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
