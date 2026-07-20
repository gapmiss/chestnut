import Foundation

/// A named palette for the pet sprite. Foundation-only (no SpriteKit) so
/// `make check` can compile and exercise theme lookup, hex parsing, and the
/// custom-override merge.
struct SpriteTheme {
    typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    let id: String
    let title: String
    let palette: [Character: RGBA]

    static let defaultID = "obsidian-night"

    /// Roles identical in every theme: transparency, mouth interior, tongue,
    /// eyes, sleep z — and the purple gem (the accent stays purple across
    /// themes; asleep dims it via `d` in the frame, not the palette).
    private static let sharedRoles: [Character: RGBA] = [
        ".": (0, 0, 0, 0),          // transparent
        "p": (155, 93, 229, 255),   // purple gem
        "P": (203, 166, 247, 255),  // purple gem, bright glint
        "k": (26, 16, 14, 255),     // dark interior (open mouth)
        "t": (233, 120, 150, 255),  // tongue pink
        "e": (240, 240, 235, 255),  // eye white
        "b": (30, 25, 35, 255),     // pupil
        "z": (170, 200, 255, 255),  // sleep "z" pixels
    ]

    private init(id: String, title: String, shell: [Character: RGBA]) {
        self.id = id
        self.title = title
        palette = Self.sharedRoles.merging(shell) { _, themed in themed }
    }

    /// Near-black graphite with a purple-tinted sheen; the gem glows. Default.
    static let obsidianNight = SpriteTheme(
        id: defaultID, title: "Obsidian Night",
        shell: [
            "s": (36, 31, 53, 255),     // #241F35 shell
            "S": (58, 53, 84, 255),     // #3A3554 highlight / rivets
            "d": (22, 18, 31, 255),     // #16121F shadow / dial face
            "m": (108, 106, 138, 255),  // #6C6A8A trim / dial ring
            "o": (10, 9, 18, 255),      // #0A0912 outline
        ]
    )

    /// The original chest: browns and gold, kept for continuity.
    static let classicWood = SpriteTheme(
        id: "classic-wood", title: "Classic Wood",
        shell: [
            "s": (139, 90, 43, 255),    // #8B5A2B wood
            "S": (176, 122, 66, 255),   // #B07A42 highlight / rivets
            "d": (90, 58, 32, 255),     // #5A3A20 shadow / dial face
            "m": (218, 165, 32, 255),   // #DAA520 gold trim / dial ring
            "o": (43, 27, 23, 255),     // #2B1B17 outline
        ]
    )

    /// Light silver, dark fittings.
    static let brushedSteel = SpriteTheme(
        id: "brushed-steel", title: "Brushed Steel",
        shell: [
            "s": (154, 163, 173, 255),  // #9AA3AD shell
            "S": (200, 208, 216, 255),  // #C8D0D8 highlight / rivets
            "d": (107, 115, 124, 255),  // #6B737C shadow / dial face
            "m": (86, 94, 104, 255),    // #565E68 trim / dial ring
            "o": (43, 47, 51, 255),     // #2B2F33 outline
        ]
    )

    /// Warm pale wood with brass fittings; pairs well with light mode.
    static let sunbleached = SpriteTheme(
        id: "sunbleached", title: "Sunbleached",
        shell: [
            "s": (228, 216, 196, 255),  // #E4D8C4 pale birch
            "S": (240, 232, 218, 255),  // #F0E8DA cream highlight / rivets
            "d": (200, 184, 156, 255),  // #C8B89C warm shadow / dial face
            "m": (196, 154, 92, 255),   // #C49A5C brass trim / dial ring
            "o": (92, 74, 56, 255),     // #5C4A38 warm brown outline
        ]
    )

    static let builtIn: [SpriteTheme] = [obsidianNight, classicWood, brushedSteel, sunbleached]
    @MainActor private static var custom: [SpriteTheme] = []

    @MainActor static var all: [SpriteTheme] { builtIn + custom }

    @MainActor static func theme(id: String) -> SpriteTheme {
        all.first { $0.id == id } ?? obsidianNight
    }

    /// Register custom themes from the config. Entries with a built-in id,
    /// missing required shell roles, or unparseable hex are skipped with a log.
    @MainActor static func registerCustomThemes(_ entries: [CustomThemeConfig]) {
        let builtInIDs = Set(builtIn.map(\.id))
        let requiredShellRoles: Set<Character> = ["s", "S", "d", "m", "o"]
        var seen = builtInIDs
        var result: [SpriteTheme] = []

        for entry in entries {
            if entry.id.isEmpty {
                NSLog("SpriteTheme: skipping custom theme with empty id")
                continue
            }
            if seen.contains(entry.id) {
                NSLog("SpriteTheme: skipping custom theme \"%@\" (duplicate id)", entry.id)
                continue
            }
            var shell: [Character: RGBA] = [:]
            var valid = true
            for (key, hex) in entry.palette {
                guard key.count == 1, let role = key.first else { continue }
                guard let color = parseHex(hex) else {
                    NSLog("SpriteTheme: bad hex \"%@\" for role '%@' in theme \"%@\"",
                          hex, key, entry.id)
                    valid = false
                    break
                }
                if role != "." { shell[role] = color }
            }
            guard valid else { continue }
            let missing = requiredShellRoles.subtracting(shell.keys)
            if !missing.isEmpty {
                NSLog("SpriteTheme: theme \"%@\" missing required roles: %@",
                      entry.id, String(missing.sorted()))
                continue
            }
            seen.insert(entry.id)
            result.append(SpriteTheme(id: entry.id, title: entry.title, shell: shell))
        }
        custom = result
    }

    /// The palette for a config selection: the theme's colors with per-role
    /// hex overrides on top. Hand-edited entries that don't parse — unknown
    /// role, multi-character key, bad hex — are ignored per-role. `.` stays
    /// untouchable: an opaque background would defeat per-pixel click-through.
    @MainActor static func resolvedPalette(
        themeID: String, overrides: [String: String]?
    ) -> [Character: RGBA] {
        var palette = theme(id: themeID).palette
        for (key, hex) in overrides ?? [:] {
            guard key.count == 1, let role = key.first, role != ".",
                  palette[role] != nil,
                  let color = parseHex(hex)
            else { continue }
            palette[role] = color
        }
        return palette
    }

    /// "#RRGGBB" or "#RRGGBBAA" (leading "#" optional, case-insensitive).
    static func parseHex(_ string: String) -> RGBA? {
        var hex = Substring(string)
        if hex.hasPrefix("#") { hex = hex.dropFirst() }
        guard hex.count == 6 || hex.count == 8,
              hex.allSatisfy(\.isHexDigit),  // UInt64.init would take a sign
              let value = UInt64(hex, radix: 16)
        else { return nil }
        let rgba = hex.count == 6 ? value << 8 | 0xFF : value
        return (
            r: UInt8((rgba >> 24) & 0xFF),
            g: UInt8((rgba >> 16) & 0xFF),
            b: UInt8((rgba >> 8) & 0xFF),
            a: UInt8(rgba & 0xFF)
        )
    }
}
