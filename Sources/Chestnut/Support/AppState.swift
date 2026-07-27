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
    /// Settings ▸ Reduce Motion: hold the pet still. Chestnut's own setting,
    /// *not* a mirror of the system one — see `motionFrozen` for how the two
    /// combine.
    var reduceMotion = false
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
    /// How long notice bubbles stay on screen, in seconds. Set from the
    /// right-click menu → Notice Duration; applies to the next bubble, with
    /// no relaunch.
    var noticeDuration = defaultNoticeDuration

    private enum CodingKeys: String, CodingKey {
        case position, size, opacity, reduceMotion, courierCopyByDefault
        case showInFullScreen, petTheme, lastCaptureVaultPath, pinnedVaultPath
        case disabledPlugins, noticeDuration
    }

    /// Whether the pet holds still.
    ///
    /// Chestnut's setting and the system's are OR-ed rather than layered into
    /// an override. The system one is a standing request the user has already
    /// made of every app on the machine, so the menu may add stillness but
    /// never take it away — an always-on-top window is the last place that
    /// request should be undone by a checkbox someone finds by accident. The
    /// cost is that a user who runs Reduce Motion system-wide can't have a
    /// lively Chestnut; the menu row says why by drawing checked and disabled,
    /// rather than looking broken. The two share a name because they mean the
    /// same thing to the user; ticking Chestnut's own never writes the
    /// system's, which the app has no business touching.
    static func motionFrozen(app: Bool, system: Bool) -> Bool {
        app || system
    }

    static let opacityRange = 0.1...1.0
    /// Slider bounds in the Notice Duration submenu, and the clamp on anything
    /// read from disk. The floor keeps a bubble readable at all.
    static let noticeDurationRange = 1.0...30.0
    static let defaultNoticeDuration = 5.0

    /// The choices offered by Settings ▸ Opacity and Settings ▸ Notice Bubble.
    ///
    /// These are the whole of each setting, not shortcuts alongside a slider.
    /// A slider in a menu is an `NSMenuItem.view`, and AppKit skips view items
    /// when navigating a menu by keyboard, so a slider could only ever be set
    /// with a mouse. Discrete items are reachable by both. The cost is that
    /// values between stops are no longer offered.
    ///
    /// Ordered as they appear in the menu. Both arrays must stay inside their
    /// range: a preset outside it would be clamped on the next read, so picking
    /// it would silently do nothing.
    static let opacityPresets: [Double] = [1.0, 0.8, 0.6, 0.4, 0.2]
    static let noticeDurationPresets: [Double] = [3, 5, 10, 20, 30]

    /// Whether a preset is the one currently in effect, for the checkmark.
    /// Exact rather than nearest: a value written between stops by an older
    /// build should show no checkmark instead of pointing at a stop the app
    /// isn't actually using.
    static func isPreset(_ preset: Double, matching value: Double) -> Bool {
        abs(preset - value) < 0.000_001
    }

    init() {}

    /// Tolerant decoding: files written by older builds lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position)
        size = try c.decodeIfPresent(PetSize.self, forKey: .size) ?? .medium
        let rawOpacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        opacity = rawOpacity.clamped(to: Self.opacityRange)
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
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
        let rawNotice = try c.decodeIfPresent(Double.self, forKey: .noticeDuration)
            ?? Self.defaultNoticeDuration
        noticeDuration = rawNotice.clamped(to: Self.noticeDurationRange)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encode(size, forKey: .size)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(reduceMotion, forKey: .reduceMotion)
        try c.encode(courierCopyByDefault, forKey: .courierCopyByDefault)
        try c.encode(showInFullScreen, forKey: .showInFullScreen)
        try c.encode(petTheme, forKey: .petTheme)
        try c.encodeIfPresent(lastCaptureVaultPath, forKey: .lastCaptureVaultPath)
        try c.encodeIfPresent(pinnedVaultPath, forKey: .pinnedVaultPath)
        if !disabledPlugins.isEmpty {
            try c.encode(disabledPlugins.sorted(), forKey: .disabledPlugins)
        }
        try c.encode(noticeDuration, forKey: .noticeDuration)
    }

    static var fileURL: URL {
        Config.fileURL.deletingLastPathComponent()
            .appendingPathComponent("state.json")
    }

    /// Loads `state.json`, falling back to defaults when it's missing or
    /// unreadable. Settings from a version that stored things elsewhere are
    /// not carried over — decoding is tolerant, so an unknown or stale key is
    /// ignored rather than fatal, and everything here is a menu click away.
    static func load() -> AppState {
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
}
