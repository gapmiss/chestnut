import AppKit
import Foundation

// Runtime check harness (`make check`) — stands in for a test target while
// this machine's toolchain lacks XCTest (see CLAUDE.md). The Makefile compiles
// it against the sources it exercises: VaultRegistry, VaultWatcher,
// ObsidianBridge. The "real obsidian.json" check assumes Obsidian is installed.

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print("\(ok ? "PASS" : "FAIL")  \(label)")
    if !ok { failures += 1 }
}

@main
struct Check {
    @MainActor
    static func main() async {
        // --- VaultRegistry.parse: fixture with duplicate names, open flags ---
        let fixture = """
        {"vaults":{
          "a":{"path":"/tmp/x/test-vault","ts":2000,"open":true},
          "b":{"path":"/tmp/y/test-vault","ts":9000},
          "c":{"path":"/tmp/z/newest","ts":9999},
          "d":{"path":"/tmp/x/test-vault","ts":1000}
        },"insider":true}
        """.data(using: .utf8)!
        do {
            let vaults = try VaultRegistry.parse(fixture)
            check(vaults.count == 3, "parse dedupes by path (3 unique of 4 entries)")
            check(vaults.first?.path == "/tmp/x/test-vault", "open vault sorts first")
            check(vaults.first?.isOpen == true, "open flag survives dedupe of older duplicate")
            check(vaults.dropFirst().first?.path == "/tmp/z/newest", "closed vaults sort by recency")
            check(vaults.allSatisfy { $0.name == "test-vault" || $0.name == "newest" }, "name is last path component")
        } catch {
            check(false, "fixture parse threw: \(error)")
        }
        check((try? VaultRegistry.parse(Data("not json".utf8))) == nil, "malformed JSON throws")

        // --- VaultRegistry.pinnedFirst ---
        if let vaults = try? VaultRegistry.parse(fixture) {
            let pinned = VaultRegistry.pinnedFirst(vaults, pinnedPath: "/tmp/z/newest")
            check(pinned.first?.path == "/tmp/z/newest"
                    && pinned.dropFirst().map(\.path) == vaults.filter { $0.path != "/tmp/z/newest" }.map(\.path),
                  "pinnedFirst hoists the pin, keeps the rest in order")
            check(VaultRegistry.pinnedFirst(vaults, pinnedPath: nil) == vaults,
                  "pinnedFirst without a pin is a no-op")
            check(VaultRegistry.pinnedFirst(vaults, pinnedPath: "/gone") == vaults,
                  "pinnedFirst ignores a pin that left the registry")
        }

        // --- VaultRegistry.parse: the real obsidian.json on this machine ---
        if let data = try? Data(contentsOf: VaultRegistry.defaultFileURL) {
            let vaults = (try? VaultRegistry.parse(data)) ?? []
            check(!vaults.isEmpty, "real obsidian.json parses (\(vaults.count) vaults, \(vaults.filter(\.isOpen).count) open)")
        } else {
            check(false, "real obsidian.json unreadable")
        }

        // --- ObsidianBridge.openURL encoding ---
        let url = ObsidianBridge.openURL(path: "/Users/gm/Library/Application Support/obsidian/Obsidian Sandbox")
        check(url?.absoluteString == "obsidian://open?path=/Users/gm/Library/Application%20Support/obsidian/Obsidian%20Sandbox",
              "openURL percent-encodes spaces (got: \(url?.absoluteString ?? "nil"))")

        // --- ObsidianBridge.focusScript embedding ---
        let script = ObsidianBridge.focusScript(vaultPath: #"/tmp/we"ird\vault"#)
        check(script.contains(#""\/tmp\/we\"ird\\vault""# ) || script.contains(#""/tmp/we\"ird\\vault""#),
              "focusScript JSON-escapes quotes and backslashes in the vault path")
        check(!script.contains("\n"), "focusScript stays on one line (CLI single-argument value)")
        check(script.contains("win.focus()") && script.contains("basePath"),
              "focusScript raises the window matched by vault basePath")

        // --- ObsidianBridge.presentScript embedding ---
        let openScript = ObsidianBridge.presentScript(
            vaultPath: "/tmp/vault", relativePath: #"attach/we"ird.png"#, open: true)
        check(!openScript.contains("\n"), "presentScript stays on one line (CLI single-argument value)")
        check(openScript.contains("openFile") && !openScript.contains("revealInFolder"),
              "presentScript open variant opens the file in a tab")
        check(openScript.contains(#"we\\\"ird.png"#),
              "presentScript double-escapes the relative path (quoted inside a quoted inner script)")
        check(openScript.contains("win.focus()") && openScript.contains("no-window"),
              "presentScript focuses the matched window and reports a retryable miss")
        let revealScript = ObsidianBridge.presentScript(
            vaultPath: "/tmp/vault", relativePath: "attachments", open: false)
        check(revealScript.contains("revealInFolder") && revealScript.contains("leftSplit.expand"),
              "presentScript reveal variant expands the sidebar and reveals in the file explorer")

        // --- VaultWatcher end to end on a temp vault ---
        let root = NSTemporaryDirectory() + "chestnut-check-vault-\(ProcessInfo.processInfo.processIdentifier)"
        let fm = FileManager.default
        try! fm.createDirectory(atPath: root + "/.obsidian", withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: root + "/.trash", withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        var signals: [String] = []
        let watcher = VaultWatcher()
        watcher.onWritingActivity = { signals.append($0) }
        watcher.watch(roots: [root])

        func settle(_ seconds: TimeInterval) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        await settle(0.5)
        try! "hello".write(toFile: root + "/notes/note.md", atomically: true, encoding: .utf8)
        await settle(3)
        check(signals == [root], "md write signals its vault root exactly once (got \(signals))")

        signals = []
        try! "cfg".write(toFile: root + "/.obsidian/app.json", atomically: true, encoding: .utf8)
        try! "gone".write(toFile: root + "/.trash/old.md", atomically: true, encoding: .utf8)
        try! "img".write(toFile: root + "/notes/pic.txt", atomically: true, encoding: .utf8)
        await settle(3)
        check(signals.isEmpty, ".obsidian / .trash / non-md are ignored (got \(signals))")

        // Debounce: two md writes in quick succession → one signal.
        signals = []
        try! "a".write(toFile: root + "/notes/a.md", atomically: true, encoding: .utf8)
        try! "b".write(toFile: root + "/notes/b.md", atomically: true, encoding: .utf8)
        await settle(3)
        check(signals.count == 1, "burst of md writes debounces to one signal (got \(signals.count))")

        watcher.stop()

        courierChecks()
        captureChecks()
        configChecks()
        hotkeyChecks()
        customThemeChecks()
        themeChecks()
        frameChecks()

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Capture

    static func captureChecks() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath:
            NSTemporaryDirectory() + "chestnut-check-capture-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: base) }

        func write(_ path: String, _ content: String) {
            let url = base.appendingPathComponent(path)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! content.write(to: url, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String? {
            try? String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
        }
        func exists(_ path: String) -> Bool {
            fm.fileExists(atPath: base.appendingPathComponent(path).path)
        }
        func vault(_ name: String) -> URL {
            let url = base.appendingPathComponent(name)
            try! fm.createDirectory(at: url.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
            return url
        }

        // A fixed local-calendar date so expectations are timezone-proof.
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 14))!

        // --- formatDailyPath: Moment token subset ---
        check(Capture.formatDailyPath(format: "YYYY-MM-DD", date: date) == "2026-07-14",
              "default daily format renders")
        check(Capture.formatDailyPath(format: "YYYY/MM/YYYY-MM-DD", date: date) == "2026/07/2026-07-14",
              "folders inside the format render (Master-style)")
        check(Capture.formatDailyPath(format: "[day] D.M.YY", date: date) == "day 14.7.26",
              "bracket literals and unpadded tokens render")
        check(Capture.formatDailyPath(format: "gggg-[W]ww", date: date) == nil,
              "unsupported tokens bail out instead of guessing")

        // --- destination: settings wiring ---
        let engine = Capture()
        let v1 = vault("v1")
        write("v1/.obsidian/daily-notes.json", #"{"format":"YYYY/MM/YYYY-MM-DD","folder":"daily"}"#)
        check(engine.destination(inVault: v1, date: date).path
                == v1.appendingPathComponent("daily/2026/07/2026-07-14.md").path,
              "daily note path honors folder + format")

        let v2 = vault("v2")  // no settings files at all
        check(engine.destination(inVault: v2, date: date).path
                == v2.appendingPathComponent("2026-07-14.md").path,
              "missing settings fall back to Obsidian defaults (YYYY-MM-DD at root)")

        let v3 = vault("v3")
        write("v3/.obsidian/core-plugins.json", #"{"daily-notes":false}"#)
        check(engine.destination(inVault: v3, date: date).path
                == v3.appendingPathComponent("Inbox.md").path,
              "disabled daily-notes plugin (dict form) → inbox")

        let v4 = vault("v4")
        write("v4/.obsidian/core-plugins.json", #"["file-explorer","graph"]"#)
        check(engine.destination(inVault: v4, date: date).path
                == v4.appendingPathComponent("Inbox.md").path,
              "plugin absent from older array form → inbox")

        let v5 = vault("v5")
        write("v5/.obsidian/daily-notes.json", #"{"format":"YYYY-MM-DD","folder":".obsidian/evil"}"#)
        check(engine.destination(inVault: v5, date: date).path
                == v5.appendingPathComponent("Inbox.md").path,
              "folder pointing into .obsidian/ → inbox")

        check(Capture(inboxFileName: "Later.md").destination(inVault: v3, date: date).path
                == v3.appendingPathComponent("Later.md").path,
              "configurable inbox name is honored")

        // --- Chestnut-native captureFormat/captureFolder ---
        let v6 = vault("v6")
        write("v6/.obsidian/core-plugins.json", #"{"daily-notes":false}"#)
        let withFormat = Capture(captureFormat: "YYYY-MM-DD", captureFolder: "captures")
        check(withFormat.destination(inVault: v6, date: date).path
                == v6.appendingPathComponent("captures/2026-07-14.md").path,
              "captureFormat+captureFolder resolve when Obsidian daily notes are off")

        let formatOnly = Capture(captureFormat: "YYYY-MM-DD")
        check(formatOnly.destination(inVault: v6, date: date).path
                == v6.appendingPathComponent("2026-07-14.md").path,
              "captureFormat without folder places at vault root")

        let noFormat = Capture(captureFormat: nil, captureFolder: "captures")
        check(noFormat.destination(inVault: v6, date: date).path
                == v6.appendingPathComponent("Inbox.md").path,
              "captureFolder without format falls back to inbox")

        // Obsidian daily notes take priority over Chestnut format.
        let v7 = vault("v7")
        write("v7/.obsidian/daily-notes.json", #"{"format":"YYYY-MM-DD","folder":"daily"}"#)
        let bothConfigured = Capture(captureFormat: "YYYY-MM-DD", captureFolder: "captures")
        check(bothConfigured.destination(inVault: v7, date: date).path
                == v7.appendingPathComponent("daily/2026-07-14.md").path,
              "Obsidian daily notes take priority over captureFormat")

        // --- existingDestination: read-only open (never creates) ---
        check(engine.existingDestination(inVault: v2, date: date) == nil,
              "existingDestination is nil before the note exists")
        write("v2/2026-07-14.md", "already here")
        check(engine.existingDestination(inVault: v2, date: date)?.path
                == v2.appendingPathComponent("2026-07-14.md").path,
              "existingDestination returns the note once it exists")

        // --- capture / append / undo round trip ---
        do {
            let first = try engine.capture("first thought \n", toVault: v1, date: date)
            check(read("v1/daily/2026/07/2026-07-14.md") == "first thought\n",
                  "capture trims trailing whitespace and creates the daily note (dirs included)")
            check(first.createdFile, "record marks the created note")

            let second = try engine.capture("second", toVault: v1, date: date)
            check(read("v1/daily/2026/07/2026-07-14.md") == "first thought\nsecond\n",
                  "second capture appends below the first")

            // Journal round trip (date compared loosely: ISO8601 drops sub-second).
            let journal = Journal<CaptureRecord>(fileURL: base.appendingPathComponent("captures.jsonl"))
            try journal.append(second)
            let restored = journal.last()
            check(restored?.notePath == second.notePath && restored?.appended == second.appended
                    && restored?.createdFile == second.createdFile,
                  "capture journal encodes and decodes the record")
            try journal.removeLast()

            try engine.undo(second)
            check(read("v1/daily/2026/07/2026-07-14.md") == "first thought\n",
                  "undo trims exactly the appended text")
            try engine.undo(first)
            check(!exists("v1/daily/2026/07/2026-07-14.md"),
                  "undo of a created note trashes it (never deletes)")

            // Leading line-breaks and indentation are deliberate spacing —
            // only trailing whitespace is normalized away.
            let spaced = try engine.capture("\n\n  - [ ] spaced  \n", toVault: v1, date: date)
            check(read("v1/daily/2026/07/2026-07-14.md") == "\n\n  - [ ] spaced\n",
                  "leading line-breaks and indentation are honored")
            try engine.undo(spaced)

            // No trailing newline at the target → a separator is added.
            write("v3/Inbox.md", "no newline")
            let inboxed = try engine.capture("stray", toVault: v3, date: date)
            check(read("v3/Inbox.md") == "no newline\nstray\n" && inboxed.appended == "\nstray\n",
                  "append separates from a note lacking a trailing newline")

            // Note edited after capture → undo refuses rather than guesses.
            write("v3/Inbox.md", "no newline\nstray\nedited later\n")
            check((try? engine.undo(inboxed)) == nil, "undo refuses when the note changed")
        } catch {
            check(false, "capture round trip threw: \(error)")
        }

        check((try? engine.capture("   ", toVault: v1, date: date)) == nil,
              "whitespace-only capture throws")
        check((try? engine.capture("\n\n", toVault: v1, date: date)) == nil,
              "newline-only capture throws")
    }

    // MARK: - Config

    static func configChecks() {
        func decode(_ json: String) -> Config? {
            try? JSONDecoder().decode(Config.self, from: Data(json.utf8))
        }
        let old = decode(#"{"size":"large"}"#)
        check(old?.opacity == 1.0, "config without opacity key defaults to 1.0")
        check(decode(#"{"opacity":0.6}"#)?.opacity == 0.6, "config opacity round-trips")
        check(decode(#"{"opacity":0.05}"#)?.opacity == Config.opacityRange.lowerBound,
              "hand-edited opacity below the floor is clamped")
        check(decode(#"{"opacity":3}"#)?.opacity == 1.0, "opacity above 1 is clamped")
        check(decode(#"{"size":"large"}"#)?.captureInboxName == "Inbox.md",
              "config without inbox key defaults to Inbox.md")
        check(decode(#"{"captureInboxName":"Later.md"}"#)?.captureInboxName == "Later.md",
              "config inbox name round-trips")
        check(decode(#"{"captureInboxName":"../evil.md"}"#)?.captureInboxName == "Inbox.md",
              "inbox name with a path separator is rejected")
        check(decode(#"{}"#)?.captureFormat == nil, "config without captureFormat defaults to nil")
        check(decode(#"{"captureFormat":"YYYY-MM-DD"}"#)?.captureFormat == "YYYY-MM-DD",
              "captureFormat round-trips")
        check(decode(#"{"captureFolder":"captures"}"#)?.captureFolder == "captures",
              "captureFolder round-trips")
        check(decode(#"{"size":"large"}"#)?.petTheme == SpriteTheme.defaultID,
              "config without theme key defaults to obsidian-night")
        check(decode(#"{"petTheme":"brushed-steel"}"#)?.petTheme == "brushed-steel",
              "config theme id round-trips")
        check(decode(#"{"petTheme":"neon-dreams"}"#)?.petTheme == "neon-dreams",
              "unknown theme id is accepted (validated after custom theme registration)")
        check(decode(##"{"petPalette":{"m":"#FF0000"}}"##)?.petPalette == ["m": "#FF0000"],
              "custom palette override survives decode verbatim")
    }

    // MARK: - Custom themes

    @MainActor static func customThemeChecks() {
        let valid = CustomThemeConfig(
            id: "test-theme", title: "Test",
            palette: ["s": "#8B5A2B", "S": "#B07A42", "d": "#5A3A20",
                       "m": "#DAA520", "o": "#2B1B17"]
        )
        SpriteTheme.registerCustomThemes([valid])
        check(SpriteTheme.all.contains { $0.id == "test-theme" },
              "valid custom theme appears in SpriteTheme.all")
        check(SpriteTheme.theme(id: "test-theme").title == "Test",
              "custom theme is findable by id")

        // Duplicate id is skipped.
        let dupe = CustomThemeConfig(
            id: "test-theme", title: "Dupe",
            palette: valid.palette
        )
        SpriteTheme.registerCustomThemes([valid, dupe])
        check(SpriteTheme.all.filter { $0.id == "test-theme" }.count == 1,
              "duplicate custom theme id is skipped")

        // Built-in id collision is skipped.
        let collision = CustomThemeConfig(
            id: "classic-wood", title: "Fake Wood",
            palette: valid.palette
        )
        SpriteTheme.registerCustomThemes([collision])
        check(SpriteTheme.theme(id: "classic-wood").title == "Classic Wood",
              "custom theme cannot shadow a built-in id")

        // Missing required role is skipped.
        let incomplete = CustomThemeConfig(
            id: "missing-role", title: "Incomplete",
            palette: ["s": "#8B5A2B", "S": "#B07A42", "d": "#5A3A20", "m": "#DAA520"]
        )
        SpriteTheme.registerCustomThemes([incomplete])
        check(!SpriteTheme.all.contains { $0.id == "missing-role" },
              "custom theme missing required role is rejected")

        // Bad hex is skipped.
        var badPalette = valid.palette
        badPalette["s"] = "notahex"
        let badHex = CustomThemeConfig(id: "bad-hex", title: "Bad", palette: badPalette)
        SpriteTheme.registerCustomThemes([badHex])
        check(!SpriteTheme.all.contains { $0.id == "bad-hex" },
              "custom theme with bad hex is rejected")

        // Config round-trip.
        func decode(_ json: String) -> Config? {
            try? JSONDecoder().decode(Config.self, from: Data(json.utf8))
        }
        check(decode(#"{}"#)?.customThemes == nil,
              "config without customThemes defaults to nil")
        let themeJSON = """
        {"customThemes":[{"id":"x","title":"X","palette":\
        {"s":"#FF0000","S":"#00FF00","d":"#0000FF","m":"#FFFF00","o":"#000000"}}]}
        """
        let decoded = decode(themeJSON)
        check(decoded?.customThemes?.count == 1 && decoded?.customThemes?[0].id == "x",
              "customThemes round-trips through config")

        // Clean up for other checks.
        SpriteTheme.registerCustomThemes([])
    }

    // MARK: - Hotkey spec parsing

    static func hotkeyChecks() {
        check(HotkeySpec("control+option+space") != nil, "default capture hotkey parses")
        check(HotkeySpec("control+option+v") != nil, "default hopper hotkey parses")
        check(HotkeySpec("control+option+o") != nil, "default notice hotkey parses")
        check(HotkeySpec("cmd+shift+k") != nil, "command+letter parses")
        check(HotkeySpec("ctrl+f12") != nil, "ctrl+F-key parses")
        check(HotkeySpec("  Control + Option + Space  ") != nil, "whitespace and case are tolerated")

        check(HotkeySpec("") == nil, "empty string returns nil")
        check(HotkeySpec("none") == nil, "\"none\" returns nil")
        check(HotkeySpec("disabled") == nil, "\"disabled\" returns nil")
        check(HotkeySpec("control+option") == nil, "modifiers without a key returns nil")
        check(HotkeySpec("control+option+a+b") == nil, "two keys returns nil")
        check(HotkeySpec("control+bogus+a") == nil, "unknown token returns nil")

        check(HotkeySpec.display("control+option+o") == "⌃⌥O", "display renders ⌃⌥O")
        check(HotkeySpec.display("cmd+shift+k") == "⇧⌘K", "display orders modifiers ⌃⌥⇧⌘")
        check(HotkeySpec.display("control+option+space") == "⌃⌥Space", "display labels space")
        check(HotkeySpec.display("ctrl+f12") == "⌃F12", "display uppercases F-keys")
        check(HotkeySpec.display("none") == nil, "display of disabled binding is nil")
        check(HotkeySpec.display("control+bogus+a") == nil, "display of malformed binding is nil")

        func decode(_ json: String) -> Config? {
            try? JSONDecoder().decode(Config.self, from: Data(json.utf8))
        }
        check(decode(#"{}"#)?.hotkeys.capture == "control+option+space",
              "config without hotkeys key uses defaults")
        check(decode(#"{"hotkeys":{"capture":"cmd+shift+c"}}"#)?.hotkeys.capture == "cmd+shift+c",
              "config hotkey override round-trips")
        check(decode(#"{"hotkeys":{"capture":"cmd+shift+c"}}"#)?.hotkeys.hopper == "control+option+v",
              "partial hotkeys object keeps defaults for missing keys")
    }

    // MARK: - Sprite themes

    @MainActor static func themeChecks() {
        // --- hex parsing ---
        func hexEquals(_ s: String, _ expected: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
            guard let c = SpriteTheme.parseHex(s) else { return false }
            return (c.r, c.g, c.b, c.a) == expected
        }
        check(hexEquals("#9B5DE5", (155, 93, 229, 255)), "parseHex handles #RRGGBB")
        check(hexEquals("9b5de5", (155, 93, 229, 255)), "parseHex is case-insensitive, # optional")
        check(hexEquals("#9B5DE580", (155, 93, 229, 128)), "parseHex handles #RRGGBBAA")
        check(SpriteTheme.parseHex("#9B5DE") == nil, "parseHex rejects wrong lengths")
        check(SpriteTheme.parseHex("#GGGGGG") == nil, "parseHex rejects non-hex digits")
        check(SpriteTheme.parseHex("+9B5DE5") == nil, "parseHex rejects a sign prefix")
        check(SpriteTheme.parseHex("") == nil, "parseHex rejects the empty string")

        // --- theme lookup ---
        check(SpriteTheme.theme(id: "classic-wood").id == "classic-wood",
              "theme lookup finds a curated theme")
        check(SpriteTheme.theme(id: "no-such-theme").id == SpriteTheme.defaultID,
              "unknown theme id resolves to the default")

        // --- every theme colors every role the frames use ---
        for theme in SpriteTheme.all {
            check(PetFrames.roleCharacters.allSatisfy { theme.palette[$0] != nil },
                  "theme \(theme.id) covers all frame role characters")
            check(theme.palette["."]?.a == 0, "theme \(theme.id) keeps '.' transparent")
        }

        // --- custom override merge ---
        let merged = SpriteTheme.resolvedPalette(
            themeID: "classic-wood",
            overrides: [
                "m": "#FF0000",     // valid: trim goes red
                "s": "notahex",     // bad hex → ignored
                "q": "#00FF00",     // unknown role → ignored
                "ss": "#0000FF",    // multi-char key → ignored
                ".": "#FFFFFFFF",   // transparency is untouchable
            ]
        )
        let wood = SpriteTheme.classicWood.palette
        check(merged["m"].map { ($0.r, $0.g, $0.b, $0.a) == (255, 0, 0, 255) } == true,
              "override recolors a valid role")
        check(merged["s"].map { ($0.r, $0.g, $0.b) == (wood["s"]!.r, wood["s"]!.g, wood["s"]!.b) } == true,
              "bad hex leaves the theme color in place")
        check(merged["q"] == nil, "unknown role is not added to the palette")
        check(merged["."]?.a == 0, "'.' override is ignored (stays transparent)")
        check(SpriteTheme.resolvedPalette(themeID: "obsidian-night", overrides: nil).count
                == SpriteTheme.obsidianNight.palette.count,
              "nil overrides resolve to the plain theme")
    }

    // MARK: - Pet frames

    static func frameChecks() {
        let failures = PetFrames.validationFailures()
        check(failures.isEmpty, "frame matrices validate (\(failures.joined(separator: "; ")))")
        check(PetFrames.gridWidth == 24 && PetFrames.gridHeight == 18,
              "grid is 24×18 (classic chest)")
        check(PetFrames.base != PetFrames.glint && PetFrames.base != PetFrames.chatterOpen,
              "variants actually differ from base")
    }

    // MARK: - Courier / Journal

    static func courierChecks() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath:
            NSTemporaryDirectory() + "chestnut-check-courier-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: base) }

        func write(_ path: String, _ content: String) {
            let url = base.appendingPathComponent(path)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! content.write(to: url, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String? {
            try? String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
        }
        func exists(_ path: String) -> Bool {
            fm.fileExists(atPath: base.appendingPathComponent(path).path)
        }

        // --- Fixture: source vault with a note + attachments, busy destination ---
        let noteContent = """
        ![[img.png]]
        see ![[shared.png|300]]
        ![pic](assets/pic%20one.jpg)
        ![ext](https://example.com/x.png)
        ![[clip [vaM_lAcnJJ8].webm]]
        ![[other-note.md]]
        """
        write("src/note.md", noteContent)
        write("src/other-note.md", "I stay put")
        write("src/second.md", "also ![[shared.png]]\n")
        write("src/clip [vaM_lAcnJJ8].webm", "CLIP")
        write("src/img.png", "IMG-A")
        write("src/shared.png", "SHARED")
        write("src/assets/pic one.jpg", "PIC")
        write("dst/.obsidian/app.json", #"{"attachmentFolderPath":"files"}"#)
        write("dst/files/img.png", "DIFFERENT")   // name conflict, other content
        write("dst/note.md", "EXISTING")          // note name conflict

        let courier = Courier()
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        let obsidianBefore = try! fm.contentsOfDirectory(atPath: dst.appendingPathComponent(".obsidian").path)

        // --- Move delivery ---
        do {
            let op = try courier.deliver(
                files: [src.appendingPathComponent("note.md"), src.appendingPathComponent("second.md")],
                toVault: dst, sourceVault: src, copy: false
            )

            let delivered = read("dst/note 1.md") ?? ""
            check(exists("dst/note 1.md") && read("dst/note.md") == "EXISTING",
                  "note conflict suffixes, never overwrites")
            check(delivered.contains("![[img 1.png]]"),
                  "conflicting attachment renamed and wikilink rewritten")
            check(read("dst/files/img 1.png") == "IMG-A" && read("dst/files/img.png") == "DIFFERENT",
                  "attachment conflict keeps both files intact")
            check(delivered.contains("![[shared.png|300]]"),
                  "wikilink display suffix (|300) survives rewrite")
            check(delivered.contains("(files/pic%20one.jpg)") && read("dst/files/pic one.jpg") == "PIC",
                  "markdown link re-pointed to attachment folder, re-encoded")
            check(delivered.contains("(https://example.com/x.png)"),
                  "external URL left alone")
            check(delivered.contains("![[clip [vaM_lAcnJJ8].webm]]")
                    && read("dst/files/clip [vaM_lAcnJJ8].webm") == "CLIP"
                    && !exists("src/clip [vaM_lAcnJJ8].webm"),
                  "embed with brackets in the filename (yt-dlp style) is carried along")
            check(exists("src/other-note.md") && !exists("dst/files/other-note.md")
                    && delivered.contains("![[other-note.md]]"),
                  "embedded note (.md target) is never carried as an attachment")
            check(op.transfers.filter { $0.from.hasSuffix("shared.png") }.count == 1
                    && (read("dst/second 1.md") ?? read("dst/second.md") ?? "").contains("![[shared.png]]"),
                  "attachment shared by two notes moves once")
            check(!exists("src/note.md") && !exists("src/img.png")
                    && !exists("src/shared.png") && !exists("src/assets/pic one.jpg"),
                  "move clears the source")
            let obsidianAfter = try! fm.contentsOfDirectory(atPath: dst.appendingPathComponent(".obsidian").path)
            check(obsidianAfter == obsidianBefore, "destination .obsidian/ untouched")

            // --- Journal round-trip + undo ---
            let journal = Journal<CourierOperation>(fileURL: base.appendingPathComponent("journal.jsonl"))
            try journal.append(op)
            let restored = journal.last()
            // date is compared loosely: ISO8601 drops sub-second precision.
            check(restored?.transfers == op.transfers && restored?.rewrites == op.rewrites
                    && restored?.isCopy == op.isCopy,
                  "journal encodes and decodes the operation")

            try courier.undo(op)
            try journal.removeLast()
            check(read("src/note.md") == noteContent,
                  "undo restores the note's original content at the source")
            check(read("src/img.png") == "IMG-A" && exists("src/shared.png")
                    && exists("src/assets/pic one.jpg"),
                  "undo brings attachments home")
            check(!exists("dst/note 1.md") && !exists("dst/files/img 1.png")
                    && read("dst/files/img.png") == "DIFFERENT",
                  "undo clears the destination, pre-existing files intact")
            check(journal.last() == nil, "journal removeLast empties the log")
        } catch {
            check(false, "move delivery threw: \(error)")
        }

        // --- Copy delivery + identical-content dedupe ---
        write("c/src/noteC.md", "![[att.png]]\n")
        write("c/src/att.png", "ATT")
        write("c/dst/att.png", "ATT")   // identical bytes already at destination
        let cSrc = base.appendingPathComponent("c/src")
        let cDst = base.appendingPathComponent("c/dst")
        do {
            let op = try courier.deliver(
                files: [cSrc.appendingPathComponent("noteC.md")],
                toVault: cDst, sourceVault: cSrc, copy: true
            )
            check(exists("c/src/noteC.md") && exists("c/src/att.png"),
                  "copy leaves the source untouched")
            check(exists("c/dst/noteC.md") && !exists("c/dst/att 1.png"),
                  "identical attachment at destination is reused, not duplicated")
            check(op.transfers.count == 1, "dedupe records no transfer for a copy")

            try courier.undo(op)
            check(!exists("c/dst/noteC.md") && exists("c/dst/att.png"),
                  "copy undo trashes the copy, keeps the pre-existing attachment")
        } catch {
            check(false, "copy delivery threw: \(error)")
        }

        // --- Content-driven traversal is refused (embeds can't escape the vault) ---
        write("t/outside/secret.key", "TOPSECRET")
        write("t/src/evil.md", """
        ![[../outside/secret.key]]
        ![md](../outside/secret.key)
        ![enc](..%2Foutside%2Fsecret.key)
        """)
        try! fm.createDirectory(at: base.appendingPathComponent("t/dst"), withIntermediateDirectories: true)
        do {
            _ = try courier.deliver(
                files: [base.appendingPathComponent("t/src/evil.md")],
                toVault: base.appendingPathComponent("t/dst"),
                sourceVault: base.appendingPathComponent("t/src"), copy: false
            )
            check(read("t/outside/secret.key") == "TOPSECRET",
                  "traversal embed leaves the outside file in place")
            let dstFiles = try! fm.subpathsOfDirectory(atPath: base.appendingPathComponent("t/dst").path)
            check(!dstFiles.contains { $0.hasSuffix("secret.key") },
                  "traversal embed carries nothing into the destination")
            check(read("t/dst/evil.md")?.contains("![[../outside/secret.key]]") == true,
                  "unresolvable traversal reference is left unrewritten")
        } catch {
            check(false, "traversal-bearing note failed to deliver: \(error)")
        }

        // --- Mid-delivery failure rolls the source back ---
        write("r/src/one.png", "ONE")
        try! fm.createDirectory(at: base.appendingPathComponent("r/dst"), withIntermediateDirectories: true)
        do {
            _ = try courier.deliver(
                files: [base.appendingPathComponent("r/src/one.png"),
                        base.appendingPathComponent("r/src/missing.png")],
                toVault: base.appendingPathComponent("r/dst"),
                sourceVault: base.appendingPathComponent("r/src"), copy: false
            )
            check(false, "delivering a missing file should throw")
        } catch {
            check(read("r/src/one.png") == "ONE",
                  "rollback returns already-moved files to the source")
            check(!exists("r/dst/one.png"),
                  "rollback clears the partial delivery from the destination")
        }

        // --- attachmentFolderPath variants ---
        for (setting, expected) in [
            (#"{"attachmentFolderPath":""}"#, ""),
            (#"{"attachmentFolderPath":"/"}"#, ""),
            (#"{"attachmentFolderPath":"./sub"}"#, "sub"),
            (#"{"attachmentFolderPath":".obsidian/evil"}"#, ""),
            (#"{"attachmentFolderPath":"../shared"}"#, ""),
        ] {
            let vault = base.appendingPathComponent("af-\(expected.isEmpty ? "root" : expected)")
            try! fm.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
            try! setting.write(to: vault.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
            let resolved = courier.attachmentFolder(of: vault)
            let expectedURL = expected.isEmpty ? vault : vault.appendingPathComponent(expected)
            check(resolved.standardizedFileURL == expectedURL.standardizedFileURL,
                  "attachmentFolderPath \(setting) → \(expected.isEmpty ? "vault root" : expected)")
        }
    }
}
