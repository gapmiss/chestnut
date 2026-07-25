import Foundation

/// Settings Chestnut writes for itself: window geometry, the choices made in
/// the right-click menu, and the breadcrumbs it leaves between launches.
///
/// Split from `Config` so the app never writes the file the user hand-edits.
/// Anything with a UI lives here; anything hand-edited lives in `Config`. A
/// window drag rewrites this file, and it must never be able to take a
/// hand-edited hotkey with it.
struct AppState: Codable, Equatable {
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
    /// Pet window opacity; the floor keeps the pet findable.
    var opacity = 1.0
    /// Courier: drops copy instead of move by default (⌥ flips either way).
    var courierCopyByDefault = false
    /// Show the pet window over full-screen apps.
    var showInFullScreen = true
    /// Sprite theme id (see SpriteTheme.all).
    var petTheme = SpriteTheme.defaultID
    /// Capture: vault that last received a quick capture (keyed by path).
    var lastCaptureVaultPath: String?
    /// User-pinned "home" vault (keyed by path): sorts first in the vault
    /// palettes and wins the capture default over lastCaptureVaultPath.
    var pinnedVaultPath: String?
    /// Plugins switched off in the right-click menu → Plugins submenu.
    var disabledPlugins: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case position, size, opacity, courierCopyByDefault, showInFullScreen
        case petTheme, lastCaptureVaultPath, pinnedVaultPath, disabledPlugins
    }

    static let opacityRange = 0.1...1.0

    init() {}

    /// Tolerant decoding: files written by older builds lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position)
        size = try c.decodeIfPresent(PetSize.self, forKey: .size) ?? .medium
        let rawOpacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        opacity = rawOpacity.clamped(to: Self.opacityRange)
        courierCopyByDefault =
            try c.decodeIfPresent(Bool.self, forKey: .courierCopyByDefault) ?? false
        showInFullScreen =
            try c.decodeIfPresent(Bool.self, forKey: .showInFullScreen) ?? true
        // Theme id validation is deferred: custom themes aren't registered yet
        // at decode time, so accept any non-empty id here. AppDelegate validates
        // after registerCustomThemes.
        petTheme = try c.decodeIfPresent(String.self, forKey: .petTheme)
            ?? SpriteTheme.defaultID
        lastCaptureVaultPath =
            try c.decodeIfPresent(String.self, forKey: .lastCaptureVaultPath)
        pinnedVaultPath = try c.decodeIfPresent(String.self, forKey: .pinnedVaultPath)
        disabledPlugins = Set(
            try c.decodeIfPresent([String].self, forKey: .disabledPlugins) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encode(size, forKey: .size)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(courierCopyByDefault, forKey: .courierCopyByDefault)
        try c.encode(showInFullScreen, forKey: .showInFullScreen)
        try c.encode(petTheme, forKey: .petTheme)
        try c.encodeIfPresent(lastCaptureVaultPath, forKey: .lastCaptureVaultPath)
        try c.encodeIfPresent(pinnedVaultPath, forKey: .pinnedVaultPath)
        if !disabledPlugins.isEmpty {
            try c.encode(disabledPlugins.sorted(), forKey: .disabledPlugins)
        }
    }

    static var fileURL: URL {
        Config.fileURL.deletingLastPathComponent()
            .appendingPathComponent("state.json")
    }

    /// Loads `state.json`, migrating from a pre-0.3 single-file `config.json`
    /// the first time (see `migrateFromLegacyConfig`).
    static func load() -> AppState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return migrateFromLegacyConfig() ?? AppState()
        }
        guard let data = try? Data(contentsOf: fileURL) else { return AppState() }
        do {
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            // Same treatment as a corrupt config: move it aside rather than
            // overwrite it, so nothing is lost to a bad parse.
            let backup = Config.availableBackupURL(
                base: fileURL.appendingPathExtension("bak"),
                exists: { FileManager.default.fileExists(atPath: $0.path) }
            )
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("State load failed (%@) — original moved to %@",
                  error.localizedDescription, backup.path)
            return AppState()
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
            NSLog("State save failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Migration from the pre-0.3 single-file config

    /// Keys that lived in `config.json` before 0.3 split app-owned state out
    /// of the hand-edited config.
    static let legacyStateKeys = [
        "position", "size", "opacity", "courierCopyByDefault",
        "showInFullScreen", "petTheme", "lastCaptureVaultPath",
        "pinnedVaultPath", "disabledPlugins",
    ]

    /// One-time split of a pre-0.3 `config.json`: app-owned keys move here,
    /// the rest stays put. Triggered by the *absence* of `state.json` rather
    /// than a version stamp, so it can't run twice or drift out of sync.
    ///
    /// Returns nil when there's nothing to migrate (a fresh install).
    static func migrateFromLegacyConfig() -> AppState? {
        let configURL = Config.fileURL
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              var json = object as? [String: Any]
        else { return nil }
        guard json.keys.contains(where: legacyStateKeys.contains) else { return nil }

        let migrated = (try? JSONDecoder().decode(AppState.self, from: data)) ?? AppState()
        // Written first: a crash before the rewrite below leaves the legacy
        // keys in config.json, where they are simply ignored from now on.
        migrated.save()

        let backup = Config.availableBackupURL(
            base: configURL.appendingPathExtension("pre-0.3"),
            exists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        do {
            try data.write(to: backup, options: .atomic)
            // Strip via the raw JSON, not a re-encoded Config, so any key
            // Chestnut doesn't model survives the rewrite.
            for key in legacyStateKeys { json.removeValue(forKey: key) }
            let stripped = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
            )
            try stripped.write(to: configURL, options: .atomic)
            NSLog("Migrated pre-0.3 config: app state moved to %@, original kept at %@",
                  fileURL.path, backup.path)
        } catch {
            NSLog("Config migration: state.json written but config.json could not be rewritten (%@) — legacy keys will be ignored",
                  error.localizedDescription)
        }
        return migrated
    }
}
