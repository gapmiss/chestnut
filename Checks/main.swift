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

        // --- VaultRegistry.parse: single-vault and empty registries ---
        let singleFixture = """
        {"vaults":{"a":{"path":"/tmp/only-vault","ts":1000,"open":true}}}
        """.data(using: .utf8)!
        do {
            let vaults = try VaultRegistry.parse(singleFixture)
            check(vaults.count == 1 && vaults.first?.path == "/tmp/only-vault",
                  "single-vault registry parses to one vault")
            check(VaultRegistry.pinnedFirst(vaults, pinnedPath: "/tmp/only-vault") == vaults,
                  "pinnedFirst with the only vault pinned is a no-op")
        } catch {
            check(false, "single-vault fixture parse threw: \(error)")
        }
        do {
            let vaults = try VaultRegistry.parse(Data(#"{"vaults":{}}"#.utf8))
            check(vaults.isEmpty, "empty registry parses to zero vaults (guards alert, no crash)")
        } catch {
            check(false, "empty registry fixture parse threw: \(error)")
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
        petGeometryChecks()
        undoMenuRowChecks()
        captureChecks()
        configChecks()
        appStateChecks()
        hotkeyChecks()
        customThemeChecks()
        themeChecks()
        frameChecks()
        pluginManifestChecks()
        await pluginRegistryChecks()
        pluginRunnerChecks()
        await pluginRunnerEndToEndChecks()
        obsidianCLIChecks()
        pluginDispatchChecks()
        dropRouterChecks()
        obsidianLinkChecks()
        docsContractChecks()

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - T7: docs / code contract

    /// Holds the published plugin reference to what the parser actually reads.
    ///
    /// Every other check here proves the app works. This one proves the
    /// *instructions* work, which is a different failure and the one that bit:
    /// the guide named the script field `command` where the parser requires
    /// `script`, so every copy-pasted manifest silently failed to load, in the
    /// reference table and both worked examples at once. Nothing in the app was
    /// broken, so nothing in the app could have caught it.
    ///
    /// Located from `#filePath` rather than the working directory, so it holds
    /// wherever the binary is run from.
    static func docsContractChecks() {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let docs = repoRoot.appendingPathComponent("docs")

        func html(_ name: String) -> String {
            (try? String(contentsOf: docs.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let guide = html("guide.html")
        let index = html("index.html")
        check(!guide.isEmpty && !index.isEmpty,
              "docs/guide.html and docs/index.html are readable from #filePath")

        // --- Reference tables vs the types they describe ---
        // First-column <code> terms of the table following a marker.
        func tableTerms(in page: String, after marker: String) -> Set<String> {
            guard let start = page.range(of: marker),
                  let open = page.range(of: "<tbody>", range: start.upperBound..<page.endIndex),
                  let close = page.range(of: "</tbody>", range: open.upperBound..<page.endIndex)
            else { return [] }
            let body = page[open.upperBound..<close.lowerBound]
            return Set(body.components(separatedBy: "<tr>").compactMap { row in
                guard let o = row.range(of: "<code>"),
                      let c = row.range(of: "</code>", range: o.upperBound..<row.endIndex)
                else { return nil }
                return String(row[o.upperBound..<c.lowerBound])
            })
        }

        let documentedFields = tableTerms(in: guide, after: "manifest.json reference")
        check(documentedFields == PluginManifest.manifestFields,
              "the manifest reference table names exactly the parser's fields "
              + "(documented-only: \(documentedFields.subtracting(PluginManifest.manifestFields).sorted()), "
              + "undocumented: \(PluginManifest.manifestFields.subtracting(documentedFields).sorted()))")

        let documentedInputs = tableTerms(in: guide, after: #"id="input-types""#)
        let realInputs = Set(PluginInputType.allCases.map(\.rawValue))
        check(documentedInputs == realInputs,
              "the input-types table lists exactly PluginInputType's cases "
              + "(missing: \(realInputs.subtracting(documentedInputs).sorted()))")

        let documentedOutputs = tableTerms(in: guide, after: #"id="output-modes""#)
        let realOutputs = Set(PluginOutputMode.allCases.map(\.rawValue))
        check(documentedOutputs == realOutputs,
              "the output-modes table lists exactly PluginOutputMode's cases "
              + "(missing: \(realOutputs.subtracting(documentedOutputs).sorted()))")

        // --- The copy-pasteable examples ---
        // A reader trusts these more than the table, and they were wrong too.
        func jsonBlocks(in page: String) -> [[String: Any]] {
            page.components(separatedBy: #"<code class="language-json">"#).dropFirst()
                .compactMap { chunk -> [String: Any]? in
                    guard let end = chunk.range(of: "</code>") else { return nil }
                    let text = String(chunk[chunk.startIndex..<end.lowerBound])
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&amp;", with: "&")
                    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                        as? [String: Any]
                }
        }

        var manifestExamples = 0
        var envelopeExamples = 0
        for (page, name) in [(guide, "guide.html"), (index, "index.html")] {
            for object in jsonBlocks(in: page) {
                let keys = Set(object.keys)
                // A manifest declares `api`; an envelope declares `action`.
                if object["api"] != nil {
                    manifestExamples += 1
                    check(keys.isSubset(of: PluginManifest.manifestFields),
                          "\(name): manifest example uses only real fields "
                          + "(stray: \(keys.subtracting(PluginManifest.manifestFields).sorted()))")
                    let accepts = Set((object["accepts"] as? [String]) ?? [])
                    check(accepts.isSubset(of: realInputs),
                          "\(name): manifest example accepts only real input types "
                          + "(stray: \(accepts.subtracting(realInputs).sorted()))")
                    check(realOutputs.contains((object["output"] as? String) ?? ""),
                          "\(name): manifest example declares a real output mode")
                } else if object["action"] != nil {
                    envelopeExamples += 1
                    check(keys.isSubset(of: PluginEnvelope.envelopeFields),
                          "\(name): envelope example uses only real fields "
                          + "(stray: \(keys.subtracting(PluginEnvelope.envelopeFields).sorted()))")
                }
            }
        }

        // Without this the loops above pass by finding nothing — the failure
        // mode of every scraper, and worse here than the drift it looks for.
        check(manifestExamples >= 2,
              "found the manifest examples to check (got \(manifestExamples), expected the guide's and the landing page's)")
        check(envelopeExamples >= 1,
              "found at least one structured-envelope example (got \(envelopeExamples))")
    }

    // MARK: - Capture

    static func captureChecks() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath:
            NSTemporaryDirectory() + "chestnut-check-capture-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: base) }

        // --- Attachments are copied only when the note refers to them ---
        // Regression test for a plugin's queued attachments surviving a
        // dismissed capture panel and riding along on the next, unrelated one.
        let png = PluginAttachment(source: "/tmp/x/scan.png", filename: "scan.png")
        let pdf = PluginAttachment(source: "/tmp/x/doc.pdf", filename: "doc.pdf")

        let wikilink = partitionAttachmentsByReference([png], inText: "![[scan.png]]")
        check(wikilink.referenced.count == 1 && wikilink.unreferenced.isEmpty,
              "attachments: wikilink reference → copied")

        let markdown = partitionAttachmentsByReference([png], inText: "![shot](scan.png)")
        check(markdown.referenced.count == 1,
              "attachments: markdown embed reference → copied")

        // The M2 scenario: draft rewritten into something unrelated.
        let rewritten = partitionAttachmentsByReference([png], inText: "buy milk")
        check(rewritten.referenced.isEmpty && rewritten.unreferenced.count == 1,
              "attachments: rewritten draft → not copied")

        let mixed = partitionAttachmentsByReference([png, pdf], inText: "see ![[doc.pdf]]")
        check(mixed.referenced.map(\.filename) == ["doc.pdf"]
              && mixed.unreferenced.map(\.filename) == ["scan.png"],
              "attachments: partition keeps referenced only")

        // An empty filename must not match every draft.
        let empty = PluginAttachment(source: "/tmp/x/y", filename: "")
        check(partitionAttachmentsByReference([empty], inText: "anything").referenced.isEmpty,
              "attachments: empty filename → not copied")

        check(partitionAttachmentsByReference([], inText: "").referenced.isEmpty,
              "attachments: no attachments → nothing copied")

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

        // The inbox is the one target with no further fallback, so Capture
        // sanitizes it on the way in rather than checking containment on the
        // way out. v3 has daily notes off, so destination lands on the inbox.
        let inboxDefault = v3.appendingPathComponent("Inbox.md").path
        for bad in ["..", ".", "", "sub/Later.md", "../escape.md"] {
            check(Capture(inboxFileName: bad).destination(inVault: v3, date: date).path
                    == inboxDefault,
                  "inbox name \"\(bad)\" is sanitized at construction, not trusted")
        }

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

        // --- D1: capture uses the one named containment predicate ---
        // Three hand-inlined copies of `Courier.isContained` lived here. They
        // are not the same function in the abstract — the copies scanned the
        // *raw* path components for ".obsidian" while `isContained` judges the
        // standardized path, so they disagree about `.obsidian/../notes/x.md`
        // (copy: reject, isContained: accept, and isContained is right, since
        // that path resolves nowhere near `.obsidian/`).
        //
        // They agree on every input that can actually arrive, and these
        // assertions are why: both producers of the relative path already
        // refuse a `..` component outright (`dailyNoteRelativePath`,
        // `chestnutDailyRelativePath`), so a path that needs standardizing to
        // judge never reaches the predicate. That upstream guard is what makes
        // swapping the predicates a no-op rather than a behavior change — if it
        // ever goes, these two implementations start disagreeing.
        let v8 = vault("v8")
        write("v8/.obsidian/core-plugins.json", #"{"daily-notes":false}"#)

        check(Capture(captureFormat: "YYYY-MM-DD", captureFolder: ".obsidian/../notes")
                .destination(inVault: v8, date: date).path
                == v8.appendingPathComponent("Inbox.md").path,
              "captureFolder with a .. component is refused upstream, before containment is asked")

        check(Capture(captureFormat: "YYYY-MM-DD", captureFolder: ".obsidian/plugins")
                .destination(inVault: v8, date: date).path
                == v8.appendingPathComponent("Inbox.md").path,
              "a captureFolder inside .obsidian/ falls back to the inbox")

        check(Capture(captureFormat: "YYYY-MM-DD", captureFolder: "../../escaped")
                .destination(inVault: v8, date: date).path
                == v8.appendingPathComponent("Inbox.md").path,
              "a captureFolder escaping the vault falls back to the inbox")

        // Same guard on Obsidian's side of the fork, where the folder comes
        // from the vault's own daily-notes.json rather than Chestnut's config.
        check(Capture.dailyNoteRelativePath(
                vault: URL(fileURLWithPath: "/tmp/nonexistent-vault"), date: date) != nil,
              "daily notes default on for a vault with no core-plugins.json")
        let v9 = vault("v9")
        write("v9/.obsidian/daily-notes.json", #"{"format":"YYYY-MM-DD","folder":"../escaped"}"#)
        check(Capture.dailyNoteRelativePath(vault: v9, date: date) == nil,
              "daily-notes.json folder with a .. component is refused upstream")
        check(engine.destination(inVault: v9, date: date).path
                == v9.appendingPathComponent("Inbox.md").path,
              "that vault's capture falls back to the inbox")

        let v10 = vault("v10")
        write("v10/.obsidian/daily-notes.json", #"{"format":"YYYY-MM-DD","folder":".obsidian/daily"}"#)
        check(engine.destination(inVault: v10, date: date).path
                == v10.appendingPathComponent("Inbox.md").path,
              "a daily-notes folder inside .obsidian/ falls back to the inbox")

        // `appendDirectly`'s precondition asserts the same predicate
        // `destination` selected on, so an ordinary capture must sail through
        // it rather than abort the app.
        let plainRecord = try? Capture(captureFormat: "YYYY-MM-DD", captureFolder: "notes")
            .appendDirectly("captured", toVault: v8, date: date)
        check(plainRecord.map {
                URL(fileURLWithPath: $0.notePath).path
                    == v8.appendingPathComponent("notes/2026-07-14.md").path
              } == true,
              "an ordinary capture passes the containment precondition and writes")

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

            // --- Undo reverses attachments too ---
            write("v1/files/shot.png", "PNG")
            var withAtt = try engine.capture("![[shot.png]]", toVault: v1, date: date)
            withAtt.attachmentPaths = [base.appendingPathComponent("v1/files/shot.png").path]
            try engine.undo(withAtt)
            check(!exists("v1/files/shot.png"),
                  "capture undo trashes the capture's attachments")

            // A refused undo must not touch the files: the text is the thing
            // the user asked to reverse, and it is still there.
            write("v3/Inbox.md", "no newline\nstray\nedited later\n")
            write("v3/files/keep.png", "PNG")
            var refused = inboxed
            refused.attachmentPaths = [base.appendingPathComponent("v3/files/keep.png").path]
            check((try? engine.undo(refused)) == nil, "undo still refuses when the note changed")
            check(exists("v3/files/keep.png"),
                  "a refused undo leaves attachments alone")

            // Records journaled before attachments were tracked must decode.
            let legacy = #"{"date":"2026-07-14T00:00:00Z","vaultPath":"/v","notePath":"/v/n.md","appended":"x","createdFile":false}"#
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let old = try? decoder.decode(CaptureRecord.self, from: Data(legacy.utf8))
            check(old != nil && old?.attachmentPaths == nil,
                  "capture record without attachmentPaths still decodes (no migration)")
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
        check(decode(#"{"size":"large"}"#)?.captureInboxName == "Inbox.md",
              "config without inbox key defaults to Inbox.md")
        check(decode(#"{"captureInboxName":"Later.md"}"#)?.captureInboxName == "Later.md",
              "config inbox name round-trips")
        check(decode(#"{"captureInboxName":"../evil.md"}"#)?.captureInboxName == "Inbox.md",
              "inbox name with a path separator is rejected")
        check(decode(#"{"captureInboxName":".."}"#)?.captureInboxName == "Inbox.md",
              "inbox name of \"..\" is rejected (no separator to catch it)")
        check(decode(#"{"captureInboxName":"."}"#)?.captureInboxName == "Inbox.md",
              "inbox name of \".\" is rejected")
        check(decode(#"{"captureInboxName":""}"#)?.captureInboxName == "Inbox.md",
              "empty inbox name is rejected")
        check(decode(#"{"captureInboxName":"sub/Later.md"}"#)?.captureInboxName == "Inbox.md",
              "inbox name naming a subfolder is rejected")
        check(decode(#"{}"#)?.captureFormat == nil, "config without captureFormat defaults to nil")
        check(decode(#"{"captureFormat":"YYYY-MM-DD"}"#)?.captureFormat == "YYYY-MM-DD",
              "captureFormat round-trips")
        check(decode(#"{"captureFolder":"captures"}"#)?.captureFolder == "captures",
              "captureFolder round-trips")
        check(decode(##"{"petPalette":{"m":"#FF0000"}}"##)?.petPalette == ["m": "#FF0000"],
              "custom palette override survives decode verbatim")
        // Keys that have moved to AppState are ignored, not resurrected: a
        // config left over from an older version decodes cleanly and
        // re-encodes without them. This tolerance is what stands in for
        // migration code — there is none, so a stale key must stay inert.
        let movedKeys = [
            "position", "size", "opacity", "courierCopyByDefault",
            "showInFullScreen", "petTheme", "lastCaptureVaultPath",
            "pinnedVaultPath", "disabledPlugins", "noticeDuration",
        ]
        let stale = decode(
            #"{"opacity":0.4,"size":"large","noticeDuration":10,"captureFolder":"c"}"#
        )
        check(stale?.captureFolder == "c", "a stale config still decodes its own keys")
        let reencoded = String(
            data: try! JSONEncoder().encode(stale!), encoding: .utf8
        )!
        for key in movedKeys {
            check(!reencoded.contains(key), "config no longer encodes the moved key \(key)")
        }

        // Corrupt configs never overwrite an earlier backup.
        let base = URL(fileURLWithPath: "/tmp/config.json.bak")
        check(Config.availableBackupURL(base: base, exists: { _ in false }) == base,
              "first backup uses the plain .bak name")
        let taken: Set<String> = ["/tmp/config.json.bak", "/tmp/config.json.bak.1"]
        check(Config.availableBackupURL(base: base, exists: { taken.contains($0.path) }).path
              == "/tmp/config.json.bak.2",
              "backup name skips past existing backups")
    }

    // MARK: - App state

    static func appStateChecks() {
        func decode(_ json: String) -> AppState? {
            try? JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        }
        check(decode(#"{}"#)?.opacity == 1.0, "state without opacity key defaults to 1.0")
        check(decode(#"{"opacity":0.6}"#)?.opacity == 0.6, "state opacity round-trips")
        check(decode(#"{"opacity":0.05}"#)?.opacity == AppState.opacityRange.lowerBound,
              "opacity below the floor is clamped")
        check(decode(#"{"opacity":3}"#)?.opacity == 1.0, "opacity above 1 is clamped")
        check(decode(#"{"size":"large"}"#)?.size == .large, "state size round-trips")
        check(decode(#"{}"#)?.petTheme == SpriteTheme.defaultID,
              "state without theme key defaults to obsidian-night")
        check(decode(#"{"petTheme":"brushed-steel"}"#)?.petTheme == "brushed-steel",
              "state theme id round-trips")
        check(decode(#"{"petTheme":"neon-dreams"}"#)?.petTheme == "neon-dreams",
              "unknown theme id is accepted (validated after custom theme registration)")
        check(decode(#"{"disabledPlugins":["a","b"]}"#)?.disabledPlugins == ["a", "b"],
              "disabledPlugins round-trips")
        check(decode(#"{}"#)?.disabledPlugins.isEmpty == true,
              "state without disabledPlugins defaults to empty")

        // An empty list is omitted entirely rather than written as [].
        var empty = AppState()
        empty.disabledPlugins = []
        let encoded = String(data: try! JSONEncoder().encode(empty), encoding: .utf8)!
        check(!encoded.contains("disabledPlugins"), "an empty disabledPlugins is not encoded")

        // Notice duration: menu-owned, so the clamp is the only guard against
        // a hand-edited state.json asking for a bubble that never leaves.
        check(decode(#"{}"#)?.noticeDuration == AppState.defaultNoticeDuration,
              "state without noticeDuration defaults to 5")
        check(decode(#"{"noticeDuration":12}"#)?.noticeDuration == 12,
              "state noticeDuration round-trips")
        check(decode(#"{"noticeDuration":0.2}"#)?.noticeDuration
              == AppState.noticeDurationRange.lowerBound,
              "noticeDuration below the floor is clamped")
        check(decode(#"{"noticeDuration":900}"#)?.noticeDuration
              == AppState.noticeDurationRange.upperBound,
              "noticeDuration above the ceiling is clamped")

        // --- Settings ▸ Opacity / Notice Bubble presets ---
        // These replaced sliders outright, so a preset that can't be selected
        // is a value the user simply cannot reach.
        let op = AppState.opacityPresets
        let nd = AppState.noticeDurationPresets
        check(op.allSatisfy { AppState.opacityRange.contains($0) },
              "every opacity preset survives the clamp applied on read")
        check(nd.allSatisfy { AppState.noticeDurationRange.contains($0) },
              "every notice-duration preset survives the clamp applied on read")
        check(Set(op).count == op.count && Set(nd).count == nd.count,
              "no duplicate presets, which would check two rows at once")
        check(op.contains(1.0), "opacity presets include fully opaque, the recovery value")
        check(nd.contains(AppState.defaultNoticeDuration),
              "notice-duration presets include the default, so it stays selectable")

        // The checkmark: exact match only, since a nearest-match would claim a
        // value the app isn't using.
        check(AppState.isPreset(0.8, matching: 0.8), "a preset in effect is checked")
        check(!AppState.isPreset(0.8, matching: 0.6), "a preset not in effect is unchecked")
        check(!op.contains { AppState.isPreset($0, matching: 0.73) },
              "a value between stops checks nothing rather than the nearest stop")
        check(op.filter { AppState.isPreset($0, matching: 0.6) }.count == 1,
              "exactly one preset is checked for a value that is one")

        // --- Settings ▸ Reduce Motion ---
        // Chestnut's row may only ever add stillness. The system setting is a
        // request the user already made of the whole machine, and an
        // always-on-top window is the last thing that should let a stray
        // checkbox undo it.
        check(!AppState.motionFrozen(app: false, system: false),
              "the pet moves when neither Chestnut nor the system asks for stillness")
        check(AppState.motionFrozen(app: true, system: false),
              "Chestnut's own Reduce Motion stills the pet")
        check(AppState.motionFrozen(app: false, system: true),
              "the system's Reduce Motion stills the pet with Chestnut's row unticked")
        check(AppState.motionFrozen(app: false, system: true)
              == AppState.motionFrozen(app: true, system: true),
              "Chestnut's row cannot release motion the system stilled")

        check(decode(#"{}"#)?.reduceMotion == false,
              "state without reduceMotion defaults to moving")
        check(decode(#"{"reduceMotion":true}"#)?.reduceMotion == true,
              "state reduceMotion round-trips")

        // A state.json from a build that predates a key decodes to defaults
        // rather than failing: the same tolerance Config relies on.
        let older = decode(#"{"opacity":0.6,"size":"small"}"#)
        check(older?.opacity == 0.6 && older?.noticeDuration == AppState.defaultNoticeDuration,
              "a state file missing newer keys decodes with defaults for them")
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

        // A registered hotkey consumes the keystroke everywhere, so a binding
        // has to carry one of ⌃⌥⌘. Shift on its own doesn't make one.
        check(HotkeySpec("space") == nil, "bare key without a modifier returns nil")
        check(HotkeySpec("a") == nil, "bare letter without a modifier returns nil")
        check(HotkeySpec("f12") == nil, "bare F-key without a modifier returns nil")
        check(HotkeySpec("shift+a") == nil, "shift alone is not enough of a modifier")
        check(HotkeySpec("control+shift+k") != nil, "shift alongside control still parses")
        check(HotkeySpec("option+shift+space") != nil, "shift alongside option still parses")
        check(HotkeySpec.display("space") == nil, "display of a modifier-less binding is nil")

        check(HotkeySpec.display("control+option+o") == "⌃⌥O", "display renders ⌃⌥O")
        check(HotkeySpec.display("cmd+shift+k") == "⇧⌘K", "display orders modifiers ⌃⌥⇧⌘")
        check(HotkeySpec.display("control+option+space") == "⌃⌥Space", "display labels space")
        check(HotkeySpec.display("ctrl+f12") == "⌃F12", "display uppercases F-keys")
        check(HotkeySpec.display("none") == nil, "display of disabled binding is nil")
        check(HotkeySpec.display("control+bogus+a") == nil, "display of malformed binding is nil")

        // The menu key equivalent comes from the same parse that backs the
        // Carbon registration — one grammar, so an equivalent the menu draws
        // is always a hotkey that fires, and vice versa.
        func equivalent(_ s: String) -> (String, NSEvent.ModifierFlags)? {
            HotkeySpec(s)?.menuKeyEquivalent
        }
        check(equivalent("control+option+v").map { $0 == ("v", [.control, .option]) } == true,
              "menu equivalent maps a letter binding")
        check(equivalent("cmd+shift+k").map { $0 == ("k", [.command, .shift]) } == true,
              "menu equivalent maps command+shift")
        check(equivalent("control+option+space").map { $0 == (" ", [.control, .option]) } == true,
              "menu equivalent maps space to \" \"")
        check(equivalent("ctrl+f1").map { $0 == (String(UnicodeScalar(NSF1FunctionKey)!), .control) } == true,
              "menu equivalent maps F-keys to function-key scalars")
        check(equivalent("shift+a") == nil,
              "menu equivalent refuses what Carbon registration refuses")
        check(equivalent("none") == nil, "menu equivalent of a disabled binding is nil")

        func decode(_ json: String) -> Config? {
            try? JSONDecoder().decode(Config.self, from: Data(json.utf8))
        }
        check(decode(#"{}"#)?.hotkeys.capture == "control+option+space",
              "config without hotkeys key uses defaults")
        check(decode(#"{"hotkeys":{"capture":"cmd+shift+c"}}"#)?.hotkeys.capture == "cmd+shift+c",
              "config hotkey override round-trips")
        check(decode(#"{"hotkeys":{"capture":"cmd+shift+c"}}"#)?.hotkeys.hopper == "control+option+v",
              "partial hotkeys object keeps defaults for missing keys")

        // The menu binding is the only keyboard route to Settings, Undo and
        // Quit, so a config written before it existed must still get one.
        check(decode(#"{"hotkeys":{"capture":"cmd+shift+c"}}"#)?.hotkeys.menu == "control+option+m",
              "a config predating the menu hotkey still gets the default binding")
        check(HotkeySpec(HotkeyConfig().menu) != nil,
              "the default menu binding parses")
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

        // --- premultiplication (the sprite bitmap is .premultipliedLast) ---
        func premul(_ c: SpriteTheme.RGBA) -> (UInt8, UInt8, UInt8, UInt8) {
            let p = SpriteTheme.premultiply(c)
            return (p.r, p.g, p.b, p.a)
        }
        check(premul((r: 155, g: 93, b: 229, a: 255)) == (155, 93, 229, 255),
              "premultiply leaves opaque pixels unchanged")
        check(premul((r: 155, g: 93, b: 229, a: 0)) == (0, 0, 0, 0),
              "premultiply zeroes fully transparent pixels")
        check(premul((r: 255, g: 128, b: 0, a: 128)) == (128, 64, 0, 128),
              "premultiply halves components at 50% alpha, rounded")
        check(premul((r: 1, g: 255, b: 254, a: 1)) == (0, 1, 1, 1),
              "premultiply never leaves a component above alpha")
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

    // MARK: - Plugin manifest

    static func pluginManifestChecks() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath:
            NSTemporaryDirectory() + "chestnut-check-plugins-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: base) }

        func writePlugin(_ name: String, manifest: String, script: String? = nil) -> URL {
            let dir = base.appendingPathComponent(name)
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try! manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            if let script {
                let scriptURL = dir.appendingPathComponent("run.sh")
                try! script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            }
            return dir
        }

        // Valid manifest.
        let validDir = writePlugin("valid", manifest: """
        {"api":1,"name":"valid","description":"A test plugin","accepts":["text","url"],"output":"capture","script":"run.sh","timeout":5}
        """, script: "#!/bin/bash\necho hello")
        if case .ok(let m) = PluginManifest.load(from: validDir) {
            check(m.name == "valid", "manifest name parses")
            check(m.description == "A test plugin", "manifest description parses")
            check(m.accepts == [.text, .url], "manifest accepts parses")
            check(m.output == .capture, "manifest output parses")
            check(m.timeout == 5, "manifest timeout parses")
        } else {
            check(false, "valid manifest should load as .ok")
        }

        // Folder type in accepts.
        let folderDir = writePlugin("folder-test", manifest: """
        {"api":1,"name":"folder-test","accepts":["folder"],"output":"structured","script":"run.sh"}
        """, script: "#!/bin/bash\necho '{}'")
        if case .ok(let m) = PluginManifest.load(from: folderDir) {
            check(m.accepts == [.folder], "folder accept type parses")
        } else {
            check(false, "manifest with folder accept should load as .ok")
        }

        // Unknown accepts aliases are silently filtered.
        let unknownDir = writePlugin("unknown-type", manifest: """
        {"api":1,"name":"unknown-type","accepts":["text","video","hologram"],"output":"notify","script":"run.sh"}
        """, script: "#!/bin/bash\necho hi")
        if case .ok(let m) = PluginManifest.load(from: unknownDir) {
            check(m.accepts == [.text], "unknown accepts aliases are filtered out")
        } else {
            check(false, "manifest with at least one valid accept should load")
        }

        // All unknown accepts → invalid.
        let allUnknownDir = writePlugin("all-unknown", manifest: """
        {"api":1,"name":"all-unknown","accepts":["video"],"output":"notify","script":"run.sh"}
        """, script: "#!/bin/bash\necho hi")
        if case .invalid = PluginManifest.load(from: allUnknownDir) {
            check(true, "all-unknown accepts → .invalid")
        } else {
            check(false, "manifest with no valid accepts should be .invalid")
        }

        // api too high.
        let futureDir = writePlugin("future", manifest: """
        {"api":99,"name":"future","accepts":["text"],"output":"capture","script":"run.sh"}
        """, script: "#!/bin/bash\necho hi")
        if case .apiTooHigh(let name, let api) = PluginManifest.load(from: futureDir) {
            check(name == "future" && api == 99, "api too high reports name and version")
        } else {
            check(false, "future api should return .apiTooHigh")
        }

        // Missing script → invalid.
        let noScriptDir = writePlugin("no-script", manifest: """
        {"api":1,"name":"no-script","accepts":["text"],"output":"capture","script":"missing.sh"}
        """)
        if case .invalid(let reason) = PluginManifest.load(from: noScriptDir) {
            check(reason.contains("not executable") || reason.contains("missing"),
                  "missing script → .invalid naming the script (\(reason))")
        } else {
            check(false, "manifest with missing script should be .invalid")
        }

        // Script path escaping plugin directory → invalid.
        let escapeDir = writePlugin("escape", manifest: """
        {"api":1,"name":"escape","accepts":["text"],"output":"capture","script":"../../etc/passwd"}
        """, script: "#!/bin/bash\necho hi")
        if case .invalid(let reason) = PluginManifest.load(from: escapeDir) {
            check(reason.contains("outside the plugin folder"),
                  "script escaping plugin dir → .invalid saying so (\(reason))")
        } else {
            check(false, "manifest with escaping script path should be .invalid")
        }

        // The M4 failure itself: a manifest using the field name the guide
        // used to document. It must be rejected with a reason that names the
        // key, not vanish silently.
        let wrongKeyDir = writePlugin("wrong-key", manifest: """
        {"api":1,"name":"wrong-key","accepts":["text"],"output":"capture","command":"run.sh"}
        """, script: "#!/bin/bash\necho hi")
        if case .invalid(let reason) = PluginManifest.load(from: wrongKeyDir) {
            check(reason.contains("did not parse") && reason.contains("script"),
                  "manifest using \"command\" instead of \"script\" → .invalid naming the key")
        } else {
            check(false, "manifest with \"command\" instead of \"script\" should be .invalid")
        }

        // Default timeout.
        let noTimeoutDir = writePlugin("no-timeout", manifest: """
        {"api":1,"name":"no-timeout","accepts":["text"],"output":"notify","script":"run.sh"}
        """, script: "#!/bin/bash\necho hi")
        if case .ok(let m) = PluginManifest.load(from: noTimeoutDir) {
            check(m.timeout == 10, "default timeout is 10")
        } else {
            check(false, "no-timeout manifest should load")
        }

        // Timeout clamping: 0 would SIGTERM the script at launch; a huge
        // value would let a hung plugin chew forever.
        let zeroTimeoutDir = writePlugin("zero-timeout", manifest: """
        {"api":1,"name":"zero-timeout","accepts":["text"],"output":"notify","script":"run.sh","timeout":0}
        """, script: "#!/bin/bash\necho hi")
        if case .ok(let m) = PluginManifest.load(from: zeroTimeoutDir) {
            check(m.timeout == PluginManifest.timeoutRange.lowerBound,
                  "timeout 0 clamped to floor")
        } else {
            check(false, "zero-timeout manifest should load")
        }
        let hugeTimeoutDir = writePlugin("huge-timeout", manifest: """
        {"api":1,"name":"huge-timeout","accepts":["text"],"output":"notify","script":"run.sh","timeout":1e9}
        """, script: "#!/bin/bash\necho hi")
        if case .ok(let m) = PluginManifest.load(from: hugeTimeoutDir) {
            check(m.timeout == PluginManifest.timeoutRange.upperBound,
                  "timeout 1e9 clamped to ceiling")
        } else {
            check(false, "huge-timeout manifest should load")
        }
        check(PluginManifest.clampedTimeout(nil) == PluginManifest.defaultTimeout,
              "clampedTimeout(nil) is the default")
        check(PluginManifest.clampedTimeout(-5) == PluginManifest.timeoutRange.lowerBound,
              "negative timeout clamped to floor")
        check(PluginManifest.clampedTimeout(30) == 30,
              "in-range timeout untouched")

        // Envelope parsing with missing optional fields.
        let envelopeJSON = #"{"action":"save","content":"hello"}"#
        if let data = envelopeJSON.data(using: .utf8),
           let env = try? JSONDecoder().decode(PluginEnvelope.self, from: data) {
            check(env.action == "save", "envelope action parses")
            check(env.content == "hello", "envelope content parses")
            check(env.filename == nil, "envelope missing filename is nil")
            check(env.vault == nil, "envelope missing vault is nil")
            check(env.folder == nil, "envelope missing folder is nil")
            check(env.notify == nil, "envelope missing notify is nil")
        } else {
            check(false, "envelope should parse with missing optional fields")
        }

        // Full envelope.
        let fullJSON = #"{"action":"save","content":"x","filename":"note.md","vault":"ask","folder":"inbox","notify":"Done!"}"#
        if let data = fullJSON.data(using: .utf8),
           let env = try? JSONDecoder().decode(PluginEnvelope.self, from: data) {
            check(env.filename == "note.md" && env.vault == "ask"
                    && env.folder == "inbox" && env.notify == "Done!",
                  "full envelope round-trips all fields")
        } else {
            check(false, "full envelope should parse")
        }

        // Unknown keys in envelope are ignored.
        let extraJSON = #"{"action":"notify","content":"hi","extraField":42}"#
        if let data = extraJSON.data(using: .utf8),
           let env = try? JSONDecoder().decode(PluginEnvelope.self, from: data) {
            check(env.action == "notify", "envelope ignores unknown keys")
        } else {
            check(false, "envelope with unknown keys should still parse")
        }
    }

    // MARK: - Plugin registry

    @MainActor static func pluginRegistryChecks() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath:
            NSTemporaryDirectory() + "chestnut-check-registry-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: base) }

        func writePlugin(_ name: String, manifest: String, script: String) {
            let dir = base.appendingPathComponent(name)
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try! manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            let scriptURL = dir.appendingPathComponent("run.sh")
            try! script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }

        try! fm.createDirectory(at: base, withIntermediateDirectories: true)

        writePlugin("alpha", manifest: """
        {"api":1,"name":"alpha","accepts":["text"],"output":"capture","script":"run.sh"}
        """, script: "#!/bin/bash\necho a")

        writePlugin("beta", manifest: """
        {"api":1,"name":"beta","accepts":["image","file"],"output":"save","script":"run.sh"}
        """, script: "#!/bin/bash\necho b")

        // Invalid: no script file (manifest references missing.sh).
        let invalidDir = base.appendingPathComponent("invalid")
        try! fm.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        try! #"{"api":1,"name":"invalid","accepts":["text"],"output":"notify","script":"missing.sh"}"#
            .write(to: invalidDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let registry = PluginRegistry(directory: base)
        registry.rescan()

        check(registry.plugins.count == 2, "registry discovers 2 valid plugins (got \(registry.plugins.count))")

        let textPlugins = registry.pluginsAccepting(.text)
        check(textPlugins.count == 1 && textPlugins.first?.0.name == "alpha",
              "pluginsAccepting(.text) returns alpha only")

        let imagePlugins = registry.pluginsAccepting(.image)
        check(imagePlugins.count == 1 && imagePlugins.first?.0.name == "beta",
              "pluginsAccepting(.image) returns beta only")

        check(registry.pluginsAccepting(.pdf).isEmpty, "pluginsAccepting(.pdf) returns nothing")

        // Disable a plugin and verify filtering.
        registry.disabled = ["alpha"]
        check(registry.pluginsAccepting(.text).isEmpty, "disabled plugin excluded from matching")
        check(registry.pluginsAccepting(.image).count == 1, "non-disabled plugin still matches")

        // Rescan after removing a plugin directory.
        try? fm.removeItem(at: base.appendingPathComponent("beta"))
        registry.rescan()
        check(registry.plugins.count == 1 && registry.plugins.first?.name == "alpha",
              "rescan reflects removed plugin")

        // --- D2: start() must create the plugins directory ---
        // It looks like dead weight: rescan() handles a missing directory, and
        // "Open Plugins Folder" creates one on demand, so an audit proposed
        // dropping it as the one thing keeping a plugin-free user's disk clean.
        // It is load-bearing. `start()` hands the path straight to
        // FSEventStreamCreate, and a stream created on a path that does not
        // exist never begins delivering events — not when the directory is
        // later created, and not for any install after that either. Measured:
        // without this line the registry saw 0 plugins through two installs
        // over 8s; with it, 1 then 2. Removing it costs hot-reload for the
        // whole session, and the user has no reason to suspect a relaunch.
        let coldBase = URL(fileURLWithPath:
            NSTemporaryDirectory() + "chestnut-check-registry-cold-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: coldBase)
        defer { try? fm.removeItem(at: coldBase) }
        let coldDir = coldBase.appendingPathComponent("never/made/plugins")
        let cold = PluginRegistry(directory: coldDir)
        cold.start()
        check(fm.fileExists(atPath: coldDir.path),
              "start() creates the plugins directory, so FSEvents watches a live path")

        // The reason, driven for real: install a plugin after start() and the
        // registry must notice without a relaunch.
        let latecomer = coldDir.appendingPathComponent("gamma")
        try! fm.createDirectory(at: latecomer, withIntermediateDirectories: true)
        try! #"{"api":1,"name":"gamma","accepts":["text"],"output":"notify","script":"run.sh"}"#
            .write(to: latecomer.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let lateScript = latecomer.appendingPathComponent("run.sh")
        try! "#!/bin/bash\necho g".write(to: lateScript, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lateScript.path)

        // Self-limiting: a regression fails this check rather than hanging it.
        let deadline = Date().addingTimeInterval(5)
        while cold.plugins.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check(cold.plugins.map(\.name) == ["gamma"],
              "a plugin installed after start() hot-reloads (got \(cold.plugins.map(\.name)))")
        cold.stop()
    }

    // MARK: - Plugin runner

    static func pluginRunnerChecks() {
        // Environment builder.
        let input = PluginRunner.Input(type: .text, text: "hello", filePath: nil, sourceApp: "com.test.app")
        let dir = URL(fileURLWithPath: "/tmp/test-plugin")
        let env = PluginRunner.environment(for: input, pluginDir: dir)
        check(env["CHESTNUT_INPUT_TYPE"] == "text", "env CHESTNUT_INPUT_TYPE is set")
        check(env["CHESTNUT_SOURCE_APP"] == "com.test.app", "env CHESTNUT_SOURCE_APP is set")
        check(env["CHESTNUT_FILE_PATH"] == "", "env CHESTNUT_FILE_PATH is empty for text input")
        check(env["CHESTNUT_PLUGIN_DIR"] == "/tmp/test-plugin", "env CHESTNUT_PLUGIN_DIR is set")
        check(env["CHESTNUT_TIMESTAMP"] != nil && !env["CHESTNUT_TIMESTAMP"]!.isEmpty, "env CHESTNUT_TIMESTAMP is set")
        check(env["PATH"] != nil, "env PATH is set")
        check(env["HOME"] != nil, "env HOME is set")

        let fileInput = PluginRunner.Input(type: .image, text: nil, filePath: "/tmp/img.png", sourceApp: nil)
        let fileEnv = PluginRunner.environment(for: fileInput, pluginDir: dir)
        check(fileEnv["CHESTNUT_INPUT_TYPE"] == "image", "env type for image input")
        check(fileEnv["CHESTNUT_FILE_PATH"] == "/tmp/img.png", "env file path for image input")
        check(fileEnv["CHESTNUT_SOURCE_APP"] == "", "env source app defaults to empty")

        // Interpret: non-zero exit.
        let failResult = PluginRunner.RawResult(exitCode: 1, stdout: "", stderr: "bad input\nsecond line")
        let failManifest = PluginManifest(api: 1, name: "t", description: "", accepts: [.text], extensions: [], output: .capture, script: "x", timeout: 10, scriptURL: URL(fileURLWithPath: "/x"))
        do {
            _ = try PluginRunner.interpret(result: failResult, manifest: failManifest)
            check(false, "non-zero exit should throw")
        } catch let e as PluginError {
            if case .nonZeroExit(let msg) = e {
                check(msg == "bad input", "non-zero exit extracts first line of stderr")
            } else {
                check(false, "expected nonZeroExit error")
            }
        } catch {
            check(false, "unexpected error type")
        }

        // Interpret: capture mode.
        let captureResult = PluginRunner.RawResult(exitCode: 0, stdout: "captured text", stderr: "")
        let captureManifest = PluginManifest(api: 1, name: "t", description: "", accepts: [.text], extensions: [], output: .capture, script: "x", timeout: 10, scriptURL: URL(fileURLWithPath: "/x"))
        if let interp = try? PluginRunner.interpret(result: captureResult, manifest: captureManifest) {
            check(interp.action == .capture, "capture mode action is .capture")
            check(interp.content == "captured text", "capture mode content is stdout")
            check(interp.filename == nil, "capture mode has no filename")
        } else {
            check(false, "capture interpret should succeed")
        }

        // Interpret: save mode extracts filename from first line.
        let saveManifest = PluginManifest(api: 1, name: "t", description: "", accepts: [.text], extensions: [], output: .save, script: "x", timeout: 10, scriptURL: URL(fileURLWithPath: "/x"))

        let saveResult = PluginRunner.RawResult(exitCode: 0, stdout: "My Note Title\nBody here", stderr: "")
        if let interp = try? PluginRunner.interpret(result: saveResult, manifest: saveManifest) {
            check(interp.filename == "My Note Title.md", "save mode filename from first line")
            check(interp.content == "Body here", "save mode content is remainder")
        } else {
            check(false, "save interpret should succeed")
        }

        // Save mode: first line already has .md extension.
        let saveMdResult = PluginRunner.RawResult(exitCode: 0, stdout: "Already.md\nStuff", stderr: "")
        if let interp = try? PluginRunner.interpret(result: saveMdResult, manifest: saveManifest) {
            check(interp.filename == "Already.md", "save mode does not double .md suffix")
        } else {
            check(false, "save interpret .md suffix should succeed")
        }

        // Save mode: slashes and backslashes replaced.
        let saveSlashResult = PluginRunner.RawResult(exitCode: 0, stdout: "a/b\\c:d\nBody", stderr: "")
        if let interp = try? PluginRunner.interpret(result: saveSlashResult, manifest: saveManifest) {
            check(interp.filename == "a-b-c-d.md", "save mode sanitizes path separators")
        } else {
            check(false, "save interpret slash sanitize should succeed")
        }

        // Save mode: blank first line falls back to nil (caller uses Untitled.md).
        let saveBlankResult = PluginRunner.RawResult(exitCode: 0, stdout: "\nBody only", stderr: "")
        if let interp = try? PluginRunner.interpret(result: saveBlankResult, manifest: saveManifest) {
            check(interp.filename == nil, "save mode blank first line yields nil filename")
            check(interp.content == "Body only", "save mode blank first line keeps body")
        } else {
            check(false, "save interpret blank line should succeed")
        }

        // Save mode: empty stdout.
        let saveEmptyResult = PluginRunner.RawResult(exitCode: 0, stdout: "", stderr: "")
        if let interp = try? PluginRunner.interpret(result: saveEmptyResult, manifest: saveManifest) {
            check(interp.filename == nil, "save mode empty stdout yields nil filename")
        } else {
            check(false, "save interpret empty should succeed")
        }

        // Non-save mode (capture) does NOT extract filename.
        let captureMultiline = PluginRunner.RawResult(exitCode: 0, stdout: "First Line\nSecond Line", stderr: "")
        if let interp = try? PluginRunner.interpret(result: captureMultiline, manifest: captureManifest) {
            check(interp.filename == nil, "capture mode does not extract filename")
            check(interp.content == "First Line\nSecond Line", "capture mode preserves full stdout")
        } else {
            check(false, "capture multiline interpret should succeed")
        }

        // Interpret: structured envelope.
        let structuredResult = PluginRunner.RawResult(
            exitCode: 0,
            stdout: #"{"action":"save","content":"hello","filename":"test.md","vault":"ask"}"#,
            stderr: ""
        )
        let structuredManifest = PluginManifest(api: 1, name: "t", description: "", accepts: [.text], extensions: [], output: .structured, script: "x", timeout: 10, scriptURL: URL(fileURLWithPath: "/x"))
        if let interp = try? PluginRunner.interpret(result: structuredResult, manifest: structuredManifest) {
            check(interp.action == .save, "structured envelope action is .save")
            check(interp.content == "hello", "structured envelope content parses")
            check(interp.filename == "test.md", "structured envelope filename parses")
            check(interp.vaultHint == "ask", "structured envelope vault hint parses")
        } else {
            check(false, "structured interpret should succeed")
        }

        // --- Plain `save` and the structured envelope share one filename
        // grammar --- The structured path used to apply none of plain save's
        // sanitizing, so "notes/today.md" addressed a directory the save never
        // creates (bare ENOENT) and "today" wrote an extension-less file
        // Obsidian won't display, reporting success. Separators become "-"
        // rather than an error because subfolders have their own field
        // (`folder`), which is created with intermediates and containment-
        // checked, so nothing is expressible only through a separator here.
        // Table-driven on purpose: the rule is "these two agree", not any
        // particular output, so a future change to the grammar only has to
        // stay consistent.
        let saveManifestT5 = PluginManifest(api: 1, name: "t", description: "", accepts: [.text], extensions: [], output: .save, script: "x", timeout: 10, scriptURL: URL(fileURLWithPath: "/x"))
        func filenameViaPlain(_ raw: String) -> String? {
            try? PluginRunner.interpret(
                result: PluginRunner.RawResult(exitCode: 0, stdout: raw + "\nbody", stderr: ""),
                manifest: saveManifestT5
            ).filename
        }
        func filenameViaStructured(_ raw: String) -> String? {
            guard let json = try? JSONSerialization.data(withJSONObject: [
                "action": "save", "content": "body", "filename": raw,
            ]), let stdout = String(data: json, encoding: .utf8) else { return nil }
            return try? PluginRunner.interpret(
                result: PluginRunner.RawResult(exitCode: 0, stdout: stdout, stderr: ""),
                manifest: structuredManifest
            ).filename
        }
        for raw in ["a/b", "x:y", "back\\slash", "no-extension", "  padded  ",
                    "already.md", "/", String(repeating: "z", count: 300)] {
            let shown = raw.count > 20 ? "\(raw.prefix(8))…(\(raw.count) chars)" : raw
            check(filenameViaPlain(raw) == filenameViaStructured(raw),
                  "filename grammar agrees across save paths: \"\(shown)\"")
        }
        check(filenameViaStructured("notes/today.md") == "notes-today.md",
              "structured filename: separator collapsed, not left addressing a directory")
        check(filenameViaStructured("today") == "today.md",
              "structured filename: .md enforced as in plain save")
        check(filenameViaStructured(String(repeating: "z", count: 300))?.count == 203,
              "structured filename: capped at 200 plus \".md\"")

        // Attachment names run through the same sanitizer, but are never
        // forced to .md — an attachment is whatever it is.
        let attJSON = #"{"action":"save","content":"b","filename":"n.md","attachments":[{"source":"/tmp/a.png","filename":"sub/pic.png"},{"source":"/tmp/b.png","filename":"   "}]}"#
        if let interp = try? PluginRunner.interpret(
            result: PluginRunner.RawResult(exitCode: 0, stdout: attJSON, stderr: ""),
            manifest: structuredManifest
        ) {
            let names = (interp.attachments ?? []).map(\.filename)
            check(names == ["sub-pic.png", "attachment"],
                  "attachment filenames are sanitized without forcing .md")
        } else {
            check(false, "attachment-bearing envelope should interpret")
        }

        // Interpret: bad structured output.
        let badStructured = PluginRunner.RawResult(exitCode: 0, stdout: "not json", stderr: "")
        do {
            _ = try PluginRunner.interpret(result: badStructured, manifest: structuredManifest)
            check(false, "bad structured output should throw")
        } catch let e as PluginError {
            if case .badStructuredOutput = e {
                check(true, "bad structured output throws .badStructuredOutput")
            } else {
                check(false, "expected badStructuredOutput error")
            }
        } catch {
            check(false, "unexpected error type for bad structured")
        }

        // Interpret: envelope with action "structured" is rejected.
        let metaStructured = PluginRunner.RawResult(
            exitCode: 0,
            stdout: #"{"action":"structured","content":"hello"}"#,
            stderr: ""
        )
        do {
            _ = try PluginRunner.interpret(result: metaStructured, manifest: structuredManifest)
            check(false, "action 'structured' in envelope should throw")
        } catch let e as PluginError {
            if case .badStructuredOutput = e {
                check(true, "action 'structured' in envelope throws .badStructuredOutput")
            } else {
                check(false, "expected badStructuredOutput for meta-structured")
            }
        } catch {
            check(false, "unexpected error type for meta-structured")
        }
    }

    // MARK: - PluginRunner end-to-end

    static func pluginRunnerEndToEndChecks() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath:
            NSTemporaryDirectory() + "chestnut-check-runner-\(ProcessInfo.processInfo.processIdentifier)")
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func writeScript(_ name: String, _ body: String) -> PluginManifest {
            let dir = base.appendingPathComponent(name)
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let scriptURL = dir.appendingPathComponent("run.sh")
            try! ("#!/bin/sh\n" + body).write(to: scriptURL, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return PluginManifest(
                api: 1, name: name, description: "", accepts: [.text],
                extensions: [], output: .capture, script: "run.sh",
                timeout: 3, scriptURL: scriptURL
            )
        }

        let input = PluginRunner.Input(type: .text, text: "hello", filePath: nil, sourceApp: nil)

        // Basic: echo stdout.
        let echo = writeScript("echo", "echo 'got it'")
        do {
            let raw = try await PluginRunner.run(manifest: echo, pluginDir: base.appendingPathComponent("echo"), input: input)
            check(raw.exitCode == 0, "runner: echo exits 0")
            check(raw.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "got it", "runner: echo stdout")
        } catch {
            check(false, "runner: echo should not throw (\(error))")
        }

        // Stdin delivery.
        let cat = writeScript("cat", "cat")
        do {
            let raw = try await PluginRunner.run(manifest: cat, pluginDir: base.appendingPathComponent("cat"), input: input)
            check(raw.stdout == "hello", "runner: stdin delivered via cat")
        } catch {
            check(false, "runner: cat should not throw (\(error))")
        }

        // Non-zero exit.
        let fail = writeScript("fail", "echo 'bad' >&2; exit 1")
        do {
            let raw = try await PluginRunner.run(manifest: fail, pluginDir: base.appendingPathComponent("fail"), input: input)
            check(raw.exitCode == 1, "runner: non-zero exit code")
            check(raw.stderr.contains("bad"), "runner: stderr captured")
        } catch {
            check(false, "runner: non-zero exit should not throw (\(error))")
        }

        // Timeout.
        let hang = PluginManifest(
            api: 1, name: "hang", description: "", accepts: [.text],
            extensions: [], output: .capture, script: "run.sh",
            timeout: 1, scriptURL: base.appendingPathComponent("hang/run.sh")
        )
        let hangDir = base.appendingPathComponent("hang")
        try! fm.createDirectory(at: hangDir, withIntermediateDirectories: true)
        let hangScript = hangDir.appendingPathComponent("run.sh")
        try! "#!/bin/sh\nsleep 30".write(to: hangScript, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hangScript.path)
        do {
            _ = try await PluginRunner.run(manifest: hang, pluginDir: hangDir, input: input)
            check(false, "runner: timeout should throw")
        } catch let e as PluginError {
            if case .timeout = e {
                check(true, "runner: timeout throws .timeout")
            } else {
                check(false, "runner: expected .timeout, got \(e)")
            }
        } catch {
            check(false, "runner: unexpected error type for timeout")
        }

        // Large stdout (>64 KB) drains without deadlock.
        let big = writeScript("big", "dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\\0' 'A'")
        do {
            let raw = try await PluginRunner.run(manifest: big, pluginDir: base.appendingPathComponent("big"), input: input)
            check(raw.exitCode == 0, "runner: large stdout exits 0")
            check(raw.stdout.count >= 128 * 1024, "runner: large stdout fully drained (\(raw.stdout.count) bytes)")
        } catch {
            check(false, "runner: large stdout should not throw (\(error))")
        }

        // A script that backgrounds a child (inheriting the stdout pipe) and
        // exits must still resolve promptly: EOF never arrives while the
        // child lives, so the grace path returns with what's buffered.
        let bg = writeScript("bg", "echo 'front'\nsleep 5 &\nexit 0")
        do {
            let started = Date()
            let raw = try await PluginRunner.run(manifest: bg, pluginDir: base.appendingPathComponent("bg"), input: input)
            let elapsed = Date().timeIntervalSince(started)
            check(raw.exitCode == 0, "runner: backgrounded child exits 0")
            check(raw.stdout.contains("front"), "runner: backgrounded child stdout captured")
            check(elapsed < 2.5, "runner: backgrounded child resolves promptly (\(elapsed)s)")
        } catch {
            check(false, "runner: backgrounded child should not throw (\(error))")
        }

        // A plugin that never reads stdin, fed more than the ~64 KB pipe
        // buffer: the write fails with EPIPE, which must not crash or hang.
        let deaf = writeScript("deaf", "exit 0")
        let bigInput = PluginRunner.Input(
            type: .text, text: String(repeating: "x", count: 200_000),
            filePath: nil, sourceApp: nil
        )
        do {
            let raw = try await PluginRunner.run(manifest: deaf, pluginDir: base.appendingPathComponent("deaf"), input: bigInput)
            check(raw.exitCode == 0, "runner: unread 200 KB stdin survives (exit 0)")
        } catch {
            check(false, "runner: unread stdin should not throw (\(error))")
        }
    }

    // MARK: - Obsidian CLI

    /// Drives `ObsidianCLI.run` against real subprocesses via its injected-
    /// executable overload. The cases that matter are the pipe ones: read only
    /// after the child exits and a reply past the ~64 KB pipe buffer blocks the
    /// child in `write()` forever, so both the large-stdout and large-stderr
    /// cases used to burn the whole timeout and answer nil. Each fixture stays
    /// self-limiting (`sleep 5`, not `sleep 30`) so a regression fails these
    /// checks instead of hanging `make check`.
    static func obsidianCLIChecks() {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("chestnut-cli-checks-\(UUID().uuidString)")
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func script(_ name: String, _ body: String) -> URL {
            let url = base.appendingPathComponent("\(name).sh")
            try! "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        // Timed so a deadlock shows up as a slow pass turning into a failure
        // rather than as a nil nobody can attribute.
        func timed(_ url: URL, timeout: TimeInterval = 2) -> (String?, TimeInterval) {
            let started = Date()
            let out = ObsidianCLI.run(url, arguments: [], timeout: timeout)
            return (out, Date().timeIntervalSince(started))
        }

        let small = timed(script("small", "echo /Users/gm/Vaults/Master"))
        check(small.0?.trimmingCharacters(in: .whitespacesAndNewlines)
                == "/Users/gm/Vaults/Master",
              "cli: short reply returned verbatim")

        // ~128 KB, twice the pipe buffer.
        let bigOut = timed(script("bigout", "dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\\0' 'A'"))
        check((bigOut.0?.utf8.count ?? 0) >= 128 * 1024,
              "cli: stdout past the pipe buffer is fully drained (\(bigOut.0?.utf8.count ?? 0) bytes)")
        check(bigOut.1 < 1.5, "cli: large stdout does not burn the timeout (\(bigOut.1)s)")

        // stderr was set and never read at all, so a long trace wedged a call
        // whose actual reply was one line.
        let bigErr = timed(script("bigerr", "dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\\0' 'A' 1>&2\necho ok"))
        check(bigErr.0?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok",
              "cli: large stderr does not block the reply")
        check(bigErr.1 < 1.5, "cli: large stderr does not burn the timeout (\(bigErr.1)s)")

        // EOF never arrives while the backgrounded child holds the write end;
        // the grace period answers with what was buffered.
        let bg = timed(script("bg", "echo front\nsleep 5 &\nexit 0"))
        check(bg.0?.trimmingCharacters(in: .whitespacesAndNewlines) == "front",
              "cli: backgrounded child's stdout still captured")
        check(bg.1 < 2.5, "cli: backgrounded child resolves on the grace path (\(bg.1)s)")

        // Past the cap the reply is not a reply; the caller falls back.
        let huge = timed(script("huge", "dd if=/dev/zero bs=1024 count=1200 2>/dev/null | tr '\\0' 'A'"))
        check(huge.0 == nil, "cli: output past maxOutputBytes is refused, not truncated silently")
        check(ObsidianCLI.maxOutputBytes == 1_048_576, "cli: output cap is 1 MB")

        check(ObsidianCLI.run(script("fail", "echo partial\nexit 3"), arguments: [], timeout: 2) == nil,
              "cli: non-zero exit returns nil")
        check(ObsidianCLI.run(script("err", "echo 'Error: no vault'"), arguments: [], timeout: 2) == nil,
              "cli: an Error reply returns nil")
        check(ObsidianCLI.run(base.appendingPathComponent("absent.sh"), arguments: [], timeout: 2) == nil,
              "cli: a missing executable returns nil rather than throwing")

        let hang = timed(script("hang", "sleep 5"), timeout: 1)
        check(hang.0 == nil, "cli: a hung child returns nil")
        check(hang.1 < 2, "cli: a hung child is bounded by the timeout (\(hang.1)s)")
    }

    // MARK: - Plugin dispatch

    static func pluginDispatchChecks() {
        check(PluginDispatch.extensionToType("png") == .image, "png → .image")
        check(PluginDispatch.extensionToType("PNG") == .image, "PNG (uppercase) → .image")
        check(PluginDispatch.extensionToType("jpg") == .image, "jpg → .image")
        check(PluginDispatch.extensionToType("jpeg") == .image, "jpeg → .image")
        check(PluginDispatch.extensionToType("gif") == .image, "gif → .image")
        check(PluginDispatch.extensionToType("heic") == .image, "heic → .image")
        check(PluginDispatch.extensionToType("webp") == .image, "webp → .image")
        check(PluginDispatch.extensionToType("svg") == .image, "svg → .image")
        check(PluginDispatch.extensionToType("tiff") == .image, "tiff → .image")
        check(PluginDispatch.extensionToType("pdf") == .pdf, "pdf → .pdf")
        check(PluginDispatch.extensionToType("PDF") == .pdf, "PDF (uppercase) → .pdf")
        check(PluginDispatch.extensionToType("zip") == .file, "zip → .file")
        check(PluginDispatch.extensionToType("docx") == .file, "docx → .file")
        check(PluginDispatch.extensionToType("txt") == .file, "txt → .file")
        check(PluginDispatch.extensionToType("") == .file, "empty extension → .file")

        check(PluginInputType(rawValue: "folder") == .folder, "folder raw value round-trips")

        // A screenshot pasteboard carries PNG *and* TIFF, so the choice of
        // bytes and the choice of name must come from one decision: naming
        // TIFF bytes `.png` embeds as a blank image in Obsidian.
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let tiffBytes = Data([0x4D, 0x4D, 0x00, 0x2A])
        var payload = PluginDispatch.imagePayload(png: pngBytes, tiff: tiffBytes)
        check(payload?.ext == "png", "pasteboard image: PNG preferred over TIFF")
        check(payload?.data == pngBytes, "pasteboard image: bytes match .png name")
        payload = PluginDispatch.imagePayload(png: nil, tiff: tiffBytes)
        check(payload?.ext == "tiff", "pasteboard image: TIFF-only names itself .tiff")
        check(payload?.data == tiffBytes, "pasteboard image: bytes match .tiff name")
        payload = PluginDispatch.imagePayload(png: pngBytes, tiff: nil)
        check(payload?.ext == "png", "pasteboard image: PNG-only stays .png")
        check(payload?.data == pngBytes, "pasteboard image: PNG-only bytes carried")
        check(PluginDispatch.imagePayload(png: nil, tiff: nil) == nil,
              "pasteboard image: no image data → nil")

        let fm = FileManager.default
        let tmpDir = URL(fileURLWithPath:
            NSTemporaryDirectory() + "chestnut-check-folder-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: tmpDir) }
        try! fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        check(tmpDir.isExistingDirectory, "temp dir detected as directory")

        let tmpFile = tmpDir.appendingPathComponent("test.txt")
        try! "hello".write(to: tmpFile, atomically: true, encoding: .utf8)
        check(!tmpFile.isExistingDirectory, "regular file not detected as directory")

        let missing = URL(fileURLWithPath: NSTemporaryDirectory() + "nonexistent-\(UUID())")
        check(!missing.isExistingDirectory, "nonexistent path not detected as directory")
    }

    // MARK: - Drop routing

    /// Every dropped URL must land in exactly one route — the failure worth
    /// testing is an item silently going nowhere, which is what the old
    /// in-window routing did to everything after the first plugin match.
    /// Plugin dispatch is single-item only: a plugin run and the courier
    /// contend for the same palette/notice surfaces (`presentPalette`
    /// dismisses both), so a multi-item drop is a delivery, wholesale.
    static func dropRouterChecks() {
        let a = URL(fileURLWithPath: "/drop/a.png")
        let b = URL(fileURLWithPath: "/drop/b.png")
        let z = URL(fileURLWithPath: "/drop/archive.zip")
        let note = URL(fileURLWithPath: "/drop/note.md")
        let dir1 = URL(fileURLWithPath: "/drop/dirA")
        let dir2 = URL(fileURLWithPath: "/drop/dirB")
        let isDir: (URL) -> Bool = { $0 == dir1 || $0 == dir2 }
        let imageOnly: (PluginInputType, String) -> Bool = { type, _ in type == .image }
        let none: (PluginInputType, String) -> Bool = { _, _ in false }

        // A single matching item is the plugin path, same as ever.
        var route = DropRouter.route([a], isDirectory: isDir,
                                     hasFolderPlugin: false, hasPluginFor: imageOnly)
        check(route.plugin == .init(type: .image, url: a) && route.courier.isEmpty,
              "router: single matching file goes to the plugin")
        route = DropRouter.route([dir1], isDirectory: isDir,
                                 hasFolderPlugin: true, hasPluginFor: none)
        check(route.plugin == .init(type: .folder, url: dir1) && route.courier.isEmpty,
              "router: single directory goes to the folder plugin")

        // A multi-item drop is a delivery, wholesale — even when a plugin
        // would match the first item. Nothing vanishes, one surface opens.
        route = DropRouter.route([a, b, note], isDirectory: isDir,
                                 hasFolderPlugin: false, hasPluginFor: imageOnly)
        check(route.plugin == nil && route.courier == [a, b, note],
              "router: multi-item drop rides the courier wholesale")
        route = DropRouter.route([dir1, dir2, note], isDirectory: isDir,
                                 hasFolderPlugin: true, hasPluginFor: none)
        check(route.plugin == nil && route.courier == [dir1, dir2, note],
              "router: multi-directory drop rides the courier wholesale")

        // A single item nothing claims falls through to the courier.
        route = DropRouter.route([z], isDirectory: isDir,
                                 hasFolderPlugin: false, hasPluginFor: imageOnly)
        check(route.plugin == nil && route.courier == [z],
              "router: single unmatched file rides the courier")
        route = DropRouter.route([dir1], isDirectory: isDir,
                                 hasFolderPlugin: false, hasPluginFor: none)
        check(route.plugin == nil && route.courier == [dir1],
              "router: single directory without a folder plugin rides the courier")

        // .md files never dispatch to a plugin.
        route = DropRouter.route([note], isDirectory: isDir,
                                 hasFolderPlugin: false, hasPluginFor: { _, _ in true })
        check(route.plugin == nil && route.courier == [note],
              "router: .md drops always go to the courier")
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

        // --- T1: isContained is lexical, by contract ---
        // It collapses `../` and rejects `.obsidian`, but does not resolve
        // symlinks. Pinned here so a future "hardening" has to change a test
        // and read the rationale in CLAUDE.md first. Purely lexical — these
        // need no files on disk.
        let vaultPath = base.appendingPathComponent("src").path
        check(Courier.isContained(base.appendingPathComponent("src/note.md"), inVault: vaultPath),
              "isContained: plain child → true")
        check(!Courier.isContained(base.appendingPathComponent("src/../escaped.md"), inVault: vaultPath),
              "isContained: ../ escape → false")
        check(!Courier.isContained(base.appendingPathComponent("src/.obsidian/app.json"), inVault: vaultPath),
              "isContained: .obsidian component → false")
        check(!Courier.isContained(base.appendingPathComponent("src"), inVault: vaultPath),
              "isContained: vault root itself → false")

        // isContainedDirectory differs from isContained on exactly one case,
        // and that difference is load-bearing: a plugin save with no `folder`
        // targets the vault root, as does attachmentFolder(of:) when
        // attachmentFolderPath is unset. Collapsing the two functions — the
        // obvious "simplification" — refuses every ordinary plugin save. It
        // exists because checking only the note path let an escaping `folder`
        // pair with a filename that walked back in: the note landed inside the
        // vault while createDirectory made the escaped folder anyway.
        check(Courier.isContainedDirectory(base.appendingPathComponent("src"), inVault: vaultPath),
              "isContainedDirectory: vault root itself → true (unlike isContained)")
        check(Courier.isContainedDirectory(base.appendingPathComponent("src/Notes/Daily"), inVault: vaultPath),
              "isContainedDirectory: nested child → true")
        check(!Courier.isContainedDirectory(base.appendingPathComponent("src/../out"), inVault: vaultPath),
              "isContainedDirectory: ../ escape → false")
        check(!Courier.isContainedDirectory(base.appendingPathComponent("src/Notes/../../etc"), inVault: vaultPath),
              "isContainedDirectory: traversal out via a nested folder → false")
        check(!Courier.isContainedDirectory(base.appendingPathComponent("src/.obsidian"), inVault: vaultPath),
              "isContainedDirectory: .obsidian component → false")
        check(!Courier.isContainedDirectory(base.appendingPathComponent("srcEvil"), inVault: vaultPath),
              "isContainedDirectory: sibling sharing a prefix → false")
        // The L1 pair, spelled out: each half looks innocent to the check the
        // other half is subject to.
        let escFolder = base.appendingPathComponent("src").appendingPathComponent("../../tmp/cn-escape")
        let escNote = escFolder.appendingPathComponent("../../\(base.lastPathComponent)/src/note.md")
        check(Courier.isContained(escNote, inVault: vaultPath),
              "L1 pair: the note path alone still passes containment")
        check(!Courier.isContainedDirectory(escFolder, inVault: vaultPath),
              "L1 pair: the escaping folder is refused, closing the gap")

        // --- T2: availableURL is the never-overwrite invariant ---
        // Two callers now: deliverNote picks a free destination, and undo picks
        // a free *source* to come home to (pinned separately below). Every
        // never-overwrite promise in the app bottoms out here, so the naming
        // rules are worth stating rather than inferring from a round trip.
        let slots = base.appendingPathComponent("slots")
        func free(_ name: String) -> String {
            Courier.availableURL(for: slots.appendingPathComponent(name)).lastPathComponent
        }
        write("slots/taken.md", "x")
        check(free("untaken.md") == "untaken.md", "availableURL: a free name is returned unchanged")
        check(free("taken.md") == "taken 1.md", "availableURL: a taken name gets Obsidian's ' 1'")
        write("slots/taken 1.md", "x")
        check(free("taken.md") == "taken 2.md", "availableURL: suffixes climb past a taken ' 1'")
        check(Courier.availableURL(for: slots.appendingPathComponent("taken.md"))
                .deletingLastPathComponent().path == slots.path,
              "availableURL: the free name stays in the requested directory")

        // Extension handling, where a naive implementation goes wrong.
        write("slots/README", "x")
        check(free("README") == "README 1",
              "availableURL: an extensionless name suffixes without gaining a dot")
        write("slots/.env", "x")
        check(free(".env") == ".env 1",
              "availableURL: a dotfile keeps its leading dot rather than suffixing before it")
        write("slots/notes.tar.gz", "x")
        check(free("notes.tar.gz") == "notes.tar 1.gz",
              "availableURL: only the last extension is treated as one")

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
            check(restored?.deliveredNames == ["note.md", "second.md"],
                  "delivery records what was dropped, in order, for the Undo row")
            check(restored?.undoMenuSubtitle == "2 notes",
                  "a real delivery names itself in the menu")

            // --- Retention: journals are capped, not grown forever ---
            let capped = Journal<CaptureRecord>(
                fileURL: base.appendingPathComponent("capped.jsonl"))
            for i in 0..<(JournalLimits.maxRecords + 15) {
                try capped.append(CaptureRecord(
                    date: Date(), vaultPath: "/v", notePath: "/v/n\(i).md",
                    appended: "x", createdFile: false))
            }
            let cappedLines = (try? String(
                contentsOf: base.appendingPathComponent("capped.jsonl"), encoding: .utf8))?
                .split(separator: "\n").count ?? 0
            check(cappedLines == JournalLimits.maxRecords,
                  "journal keeps exactly maxRecords (got \(cappedLines))")
            check(capped.last()?.notePath == "/v/n\(JournalLimits.maxRecords + 14).md",
                  "trimming drops the oldest, newest still on top")

            // A single record can carry a whole note body, so the byte
            // ceiling has to bite before the record count does.
            let heavy = Journal<CaptureRecord>(
                fileURL: base.appendingPathComponent("heavy.jsonl"))
            let bigBody = String(repeating: "x", count: 300_000)
            for i in 0..<6 {
                try heavy.append(CaptureRecord(
                    date: Date(), vaultPath: "/v", notePath: "/v/big\(i).md",
                    appended: bigBody, createdFile: false))
            }
            let heavySize = (try? FileManager.default.attributesOfItem(
                atPath: base.appendingPathComponent("heavy.jsonl").path)[.size] as? Int) ?? 0
            check(heavySize <= JournalLimits.maxBytes,
                  "byte ceiling trims below the record cap (\(heavySize) bytes)")
            check(heavy.last()?.notePath == "/v/big5.md",
                  "byte-trimmed journal still returns the newest record")

            // --- T4 / L5: the byte cap against a *single* oversized record ---
            // `trimmed` stops at one record rather than leave an empty journal,
            // so it can never trim a record that blows the cap on its own. The
            // courier's `original` is exactly that case: a whole note body.
            // `append` sheds the payload instead of storing it or dropping the
            // record, and the reversal — the part users want — must survive.
            let oversized = base.appendingPathComponent("oversized.jsonl")
            let shedJournal = Journal<CourierOperation>(fileURL: oversized)
            let hugeBody = String(repeating: "x", count: JournalLimits.maxBytes * 2)
            try shedJournal.append(CourierOperation(
                date: Date(), isCopy: false,
                transfers: [.init(from: "/a/big.md", to: "/b/big.md", dedup: false)],
                rewrites: [.init(notePath: "/b/big.md", original: hugeBody)],
                deliveredNames: ["big.md"]))
            let shedSize = (try? FileManager.default.attributesOfItem(
                atPath: oversized.path)[.size] as? Int) ?? 0
            check(shedSize < JournalLimits.maxBytes,
                  "a single oversized record is shed below the byte cap (\(shedSize) bytes)")
            let shedBack = shedJournal.last()
            check(shedBack != nil,
                  "a shed record still decodes — an empty journal would read as nothing to undo")
            check(shedBack?.transfers.count == 1,
                  "shedding keeps the transfers, which are what undo reverses")
            check(shedBack?.rewrites.isEmpty == true,
                  "shedding drops the note body it could not afford to keep")
            check(shedBack?.textNotRestored == ["big.md"],
                  "a shed record names the note whose text undo can no longer restore")
            check(shedBack?.deliveredNames == ["big.md"],
                  "shedding keeps the Undo row's subtitle")

            // Shedding is a last resort, not the normal path: an ordinary
            // record keeps its text so undo restores it exactly.
            let ordinary = Journal<CourierOperation>(
                fileURL: base.appendingPathComponent("ordinary.jsonl"))
            try ordinary.append(CourierOperation(
                date: Date(), isCopy: false,
                transfers: [.init(from: "/a/s.md", to: "/b/s.md", dedup: false)],
                rewrites: [.init(notePath: "/b/s.md", original: "the original text")],
                deliveredNames: ["s.md"]))
            check(ordinary.last()?.rewrites.first?.original == "the original text",
                  "a record under the cap keeps its rewrite payload")
            check(ordinary.last()?.textNotRestored == nil,
                  "an unshed record warns about nothing")

            // A copy is undone by trashing the copy; the source was never
            // rewritten, so there is no text to warn about losing.
            let copies = Journal<CourierOperation>(
                fileURL: base.appendingPathComponent("copies.jsonl"))
            try copies.append(CourierOperation(
                date: Date(), isCopy: true,
                transfers: [.init(from: "/a/c.md", to: "/b/c.md", dedup: false)],
                rewrites: [.init(notePath: "/b/c.md", original: hugeBody)],
                deliveredNames: ["c.md"]))
            check(copies.last()?.rewrites.isEmpty == true,
                  "an oversized copy record sheds too")
            check(copies.last()?.textNotRestored == nil,
                  "a shed copy record warns about nothing — undo trashes the copy")

            // Nothing to give up: large for another reason, so keep it whole
            // rather than mangle a record shedding cannot shrink.
            let wide = Journal<CourierOperation>(
                fileURL: base.appendingPathComponent("wide.jsonl"))
            let manyTransfers = (0..<30_000).map {
                CourierOperation.FileTransfer(from: "/a/\($0)", to: "/b/\($0)", dedup: false)
            }
            try wide.append(CourierOperation(
                date: Date(), isCopy: false, transfers: manyTransfers,
                rewrites: [], deliveredNames: ["many"]))
            check(wide.last()?.transfers.count == 30_000,
                  "an oversized record with nothing to shed is kept whole")

            // A capture's `appended` is the undo instruction, not a copy of
            // anything — shedding it would delete the wrong bytes. Oversized
            // captures are kept whole, and that limit is deliberate.
            let bigCapture = Journal<CaptureRecord>(
                fileURL: base.appendingPathComponent("bigcapture.jsonl"))
            try bigCapture.append(CaptureRecord(
                date: Date(), vaultPath: "/v", notePath: "/v/n.md",
                appended: hugeBody, createdFile: false))
            check(bigCapture.last()?.appended.count == hugeBody.count,
                  "a capture record keeps `appended` whole — it is what undo strips off")

            // Undo of a shed record against real files: everything comes home,
            // and the outcome says the text did not.
            let shedSrc = base.appendingPathComponent("shed-src")
            let shedDst = base.appendingPathComponent("shed-dst")
            try FileManager.default.createDirectory(at: shedSrc, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shedDst, withIntermediateDirectories: true)
            let shedDelivered = shedDst.appendingPathComponent("big.md")
            try "links as the delivery rewrote them".write(
                to: shedDelivered, atomically: true, encoding: .utf8)
            let shedOutcome = try Courier().undo(CourierOperation(
                date: Date(), isCopy: false,
                transfers: [.init(
                    from: shedSrc.appendingPathComponent("big.md").path,
                    to: shedDelivered.path, dedup: false)],
                rewrites: [], deliveredNames: ["big.md"],
                textNotRestored: ["big.md"]))
            check(FileManager.default.fileExists(
                    atPath: shedSrc.appendingPathComponent("big.md").path),
                  "undo of a shed record still brings the file home")
            check(!FileManager.default.fileExists(atPath: shedDelivered.path),
                  "undo of a shed record clears the destination")
            check(shedOutcome.textNotRestored == ["big.md"],
                  "undo reports the note it could not restore the text of")

            // The ordinary undo says nothing, so the notice can't cry wolf.
            let quietDst = shedDst.appendingPathComponent("quiet.md")
            try "x".write(to: quietDst, atomically: true, encoding: .utf8)
            let quietOutcome = try Courier().undo(CourierOperation(
                date: Date(), isCopy: false,
                transfers: [.init(
                    from: shedSrc.appendingPathComponent("quiet.md").path,
                    to: quietDst.path, dedup: false)],
                rewrites: [], deliveredNames: ["quiet.md"]))
            check(quietOutcome.textNotRestored.isEmpty,
                  "an ordinary undo reports nothing left unrestored")

            // --- T6 / L10: a malformed trailing line does not jam undo ---
            // Appends are whole-file atomic writes since M6, so this build
            // cannot produce a half-line — but every journal written by an
            // earlier build could, and those files are still on disk. A strict
            // last() returned nil there, which reads as "nothing to undo": the
            // row disables, and a disabled row can't be clicked, so U2's
            // Discard Entry couldn't reach it either.
            let torn = base.appendingPathComponent("torn.jsonl")
            let good = Journal<CaptureRecord>(fileURL: torn)
            try good.append(CaptureRecord(
                date: Date(), vaultPath: "/v", notePath: "/v/kept.md",
                appended: "x", createdFile: false))
            let intact = try! String(contentsOf: torn, encoding: .utf8)
            try! (intact + #"{"vaultPath":"/v","notePa"# + "\n")
                .write(to: torn, atomically: true, encoding: .utf8)

            check(good.last()?.notePath == "/v/kept.md",
                  "last() walks back past a malformed trailing line")

            // The trap the walk has to avoid: a line-counting removeLast would
            // drop the damage and leave kept.md on top, so the next click would
            // reverse the same operation a second time against real files.
            // Both resolve the top through topIndex, so they can't disagree.
            try good.removeLast()
            check(good.last() == nil,
                  "removeLast drops the record last() named, not the line above it")
            let swept = try! String(contentsOf: torn, encoding: .utf8)
            check(swept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  "the malformed line is swept along with the record beneath it")

            // Nothing decodable at all: there is genuinely nothing to undo, so
            // the disabled row is correct and removeLast is a no-op.
            let allBad = base.appendingPathComponent("allbad.jsonl")
            try! (#"{"notePa"# + "\n" + #"{"vaultP"# + "\n")
                .write(to: allBad, atomically: true, encoding: .utf8)
            let unreadable = Journal<CaptureRecord>(fileURL: allBad)
            check(unreadable.last() == nil,
                  "a journal with no decodable line has nothing to undo")
            try unreadable.removeLast()
            check(unreadable.last() == nil,
                  "removeLast on an unreadable journal is a no-op, not a throw")

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

        // --- Self-delivery through a symlinked vault spelling ---
        // obsidian.json can list one directory twice (once through a symlink;
        // the registry dedupes by exact string), and `destinationIsSource`
        // compares standardized paths, which don't resolve symlinks. The
        // delivery then reaches `place` with source and destination naming
        // the same file — where the dedup branch would read the "existing
        // copy" as redundant and delete the only copy.
        write("s/real/solo.md", "ONLY COPY")
        let sReal = base.appendingPathComponent("s/real")
        let sLink = base.appendingPathComponent("s/link")
        try! fm.createSymbolicLink(at: sLink, withDestinationURL: sReal)
        check(Courier.isSameFile(sReal.appendingPathComponent("solo.md"),
                                 sLink.appendingPathComponent("solo.md")),
              "isSameFile: one file under two spellings → true")
        check(!Courier.isSameFile(cSrc.appendingPathComponent("att.png"),
                                  cDst.appendingPathComponent("att.png")),
              "isSameFile: identical bytes in two distinct files → false")
        check(!Courier.isSameFile(sReal.appendingPathComponent("ghost.md"),
                                  sReal.appendingPathComponent("ghost.md")),
              "isSameFile: missing file → false")
        do {
            let op = try courier.deliver(
                files: [sReal.appendingPathComponent("solo.md")],
                toVault: sLink, sourceVault: sReal, copy: false
            )
            check(read("s/real/solo.md") == "ONLY COPY",
                  "delivering a note onto itself leaves the only copy in place")
            check(op.transfers.isEmpty,
                  "self-delivery records nothing for undo to reverse")
        } catch {
            check(false, "self-delivery threw: \(error)")
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

        // --- An undecodable note is refused, not half-delivered ---
        // deliverNote used to coerce the read failure to "", which resolves no
        // references: the note moved alone, its attachments stayed behind, no
        // rewrite was journaled, and the operation reported success. Reachable
        // without any exotic encoding — a dataless iCloud placeholder fails the
        // read the same way. The contract is refusal, so the rollback path
        // leaves the source vault as it was.
        let badVault = base.appendingPathComponent("u/src")
        try! fm.createDirectory(at: badVault, withIntermediateDirectories: true)
        try! fm.createDirectory(at: base.appendingPathComponent("u/dst"),
                                withIntermediateDirectories: true)
        var undecodable = Data("![[pic.png]]\n".utf8)
        undecodable.append(contentsOf: [0xFF, 0xFE, 0x21])
        try! undecodable.write(to: badVault.appendingPathComponent("broken.md"))
        write("u/src/pic.png", "PNGDATA")
        do {
            _ = try courier.deliver(
                files: [badVault.appendingPathComponent("broken.md")],
                toVault: base.appendingPathComponent("u/dst"),
                sourceVault: badVault, copy: false
            )
            check(false, "an undecodable note should not deliver")
        } catch let error as CourierError {
            if case .unreadableNote = error {
                check(true, "undecodable note throws .unreadableNote")
            } else {
                check(false, "expected .unreadableNote, got \(error)")
            }
            check(exists("u/src/broken.md"), "refused note stays at its source")
            check(exists("u/src/pic.png"), "refused note's attachment stays at its source")
            let left = (try? fm.contentsOfDirectory(
                atPath: base.appendingPathComponent("u/dst").path)) ?? ["?"]
            check(left.isEmpty, "refused delivery leaves the destination untouched")
        } catch {
            check(false, "undecodable note threw the wrong error type: \(error)")
        }

        // Control against over-refusal: a readable note whose embed does not
        // exist still delivers. The refusal above must key off the *note* being
        // unreadable, not off any reference failing to resolve.
        write("u/src/fine.md", "![[nope.png]]\n")
        do {
            let op = try courier.deliver(
                files: [badVault.appendingPathComponent("fine.md")],
                toVault: base.appendingPathComponent("u/dst"),
                sourceVault: badVault, copy: false
            )
            check(op.transfers.count == 1 && exists("u/dst/fine.md"),
                  "readable note with a missing embed still delivers")
        } catch {
            check(false, "readable note with a missing embed was refused: \(error)")
        }

        // --- T3/U3: one unreversible transfer must not strand the rest ---
        // The realistic trigger is a delivered file the user has since deleted
        // or renamed in Obsidian. Three notes, with the *middle* one deleted
        // from the destination: undo walks in reverse, so a hard stop on it
        // would leave `a.md` stranded at the destination with nothing saying
        // so. Every transfer is attempted, and the ones that can't be are
        // named in the error.
        write("u/src/a.md", "A")
        write("u/src/b.md", "B")
        write("u/src/c.md", "C")
        try! fm.createDirectory(at: base.appendingPathComponent("u/dst"), withIntermediateDirectories: true)
        do {
            let op = try courier.deliver(
                files: ["a.md", "b.md", "c.md"].map {
                    base.appendingPathComponent("u/src/\($0)")
                },
                toVault: base.appendingPathComponent("u/dst"),
                sourceVault: base.appendingPathComponent("u/src"), copy: false
            )
            check(op.transfers.count == 3 && op.transfers[0].to.hasSuffix("a.md"),
                  "three notes deliver as three transfers, in drop order")

            try! fm.removeItem(at: base.appendingPathComponent("u/dst/b.md"))
            do {
                try courier.undo(op)
                check(false, "undo of a deleted delivered file should report it")
            } catch {
                if case let CourierError.partiallyUndone(restored, unreachable) = error {
                    check(restored == 2 && unreachable == ["b.md"],
                          "partial undo counts what came home and names what didn't")
                    check(error.localizedDescription.contains("b.md")
                            && error.localizedDescription.contains("Brought back 2 files"),
                          "the message tells the user which files stayed put")
                } else {
                    check(false, "undo threw \(error), not partiallyUndone")
                }
                check(read("u/src/a.md") == "A" && read("u/src/c.md") == "C",
                      "a transfer that can't be reversed doesn't strand the ones behind it")
                check(!exists("u/dst/a.md") && !exists("u/dst/c.md"),
                      "everything reversible is cleared from the destination")
                check(!exists("u/src/b.md"),
                      "the file the user deleted is not conjured back")
            }
        } catch {
            check(false, "T3 fixture failed to deliver: \(error)")
        }

        // The audit proposed pre-occupying a transfer's source as the way to
        // make undo throw. It is not: undo routes the source through
        // `availableURL`, so a file sitting at the original path gets a " 1"
        // suffix and undo succeeds. Pinned so the next reader doesn't have to
        // re-derive it — and because never-overwrite has to hold on the way
        // back too, not just on delivery.
        write("u2/src/note.md", "ORIGINAL")
        try! fm.createDirectory(at: base.appendingPathComponent("u2/dst"), withIntermediateDirectories: true)
        do {
            let op = try courier.deliver(
                files: [base.appendingPathComponent("u2/src/note.md")],
                toVault: base.appendingPathComponent("u2/dst"),
                sourceVault: base.appendingPathComponent("u2/src"), copy: false
            )
            write("u2/src/note.md", "WRITTEN SINCE")   // source path re-occupied
            try courier.undo(op)
            check(read("u2/src/note.md") == "WRITTEN SINCE",
                  "undo never overwrites a re-occupied source path")
            check(read("u2/src/note 1.md") == "ORIGINAL",
                  "undo suffixes rather than throwing when the source path is taken")
        } catch {
            check(false, "undo with a re-occupied source threw: \(error)")
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

    // MARK: - Pet window geometry

    /// T9: where the pet lands, and how a saved position is made safe. These
    /// guard against a window the user cannot reach — the sprite is the only
    /// mouse route to the menu, so an origin with no screen under it takes
    /// Reset Position and Quit with it. Pure maths: `PetGeometry` takes screen
    /// rects rather than `NSScreen` precisely so this can run headless.
    static func petGeometryChecks() {
        // .small: scale 4, so a 24×18 grid gives a 96×72 sprite, and the
        // window adds 24 either side, 8 below, 56 above.
        let size = PetGeometry.contentSize(for: .small)
        check(size == NSSize(width: 144, height: 136),
              "content size is the sprite plus its margins (got \(size))")
        let sprite = PetGeometry.petRect(
            inWindowFrame: NSRect(x: 100, y: 200, width: 144, height: 136), scale: 4)
        check(sprite == NSRect(x: 124, y: 208, width: 96, height: 72),
              "the sprite sits inset from the window frame (got \(sprite))")

        // One display with a menu bar and a Dock: frame is the whole panel,
        // visibleFrame is what's left.
        let main = PetScreen(frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
                             visibleFrame: NSRect(x: 0, y: 50, width: 1000, height: 720))
        func validated(_ saved: NSPoint?, screens: [PetScreen] = [main]) -> NSPoint {
            PetGeometry.validatedOrigin(saved, for: .small, screens: screens,
                                        mainVisible: main.visibleFrame)
        }

        let fallback = NSPoint(x: 816, y: 90)   // bottom-right, inset 40
        check(validated(nil) == fallback,
              "no saved position → the default corner")
        check(validated(NSPoint(x: 50_000, y: 50_000)) == fallback,
              "a saved position with no screen under it → the default corner")
        check(validated(NSPoint(x: 400, y: 300)) == NSPoint(x: 400, y: 300),
              "a position wholly on screen is left exactly where it was")

        // The interesting half: partly off-screen is *clamped*, not reset.
        // Resetting would throw away a position the user chose.
        check(validated(NSPoint(x: 960, y: 400)) == NSPoint(x: 880, y: 400),
              "a position hanging off the right edge is pulled back in, not reset")
        check(validated(NSPoint(x: 400, y: 0)) == NSPoint(x: 400, y: 42),
              "a sprite under the Dock is lifted clear of it, not reset")

        // Intersection is tested against `frame`, clamping against
        // `visibleFrame`. A sprite entirely behind the Dock is still on a
        // display the user can see, so it must be rescued in place.
        check(validated(NSPoint(x: 400, y: -8)) != fallback,
              "a sprite entirely within the Dock strip is clamped, not sent to the corner")

        // Two displays: the clamp must use the screen the pet is actually on.
        let second = PetScreen(frame: NSRect(x: 1000, y: 0, width: 1000, height: 800),
                               visibleFrame: NSRect(x: 1000, y: 50, width: 1000, height: 720))
        check(validated(NSPoint(x: 1960, y: 300), screens: [main, second])
                == NSPoint(x: 1880, y: 300),
              "a pet on the second display is clamped to that display, not the main one")
        // M14: the same origin once that display is unplugged.
        check(validated(NSPoint(x: 1960, y: 300)) == fallback,
              "unplugging the display the pet was on brings it back to the main one")
        check(validated(NSPoint(x: 400, y: 300), screens: []) == fallback,
              "an empty display list still yields a usable origin")

        // Clamping is a no-op once the sprite is inside, so re-running it on
        // every screen change can't walk the window across the desktop.
        let once = PetGeometry.clampedOrigin(
            NSPoint(x: 960, y: 400), for: .small, onVisible: main.visibleFrame)
        let twice = PetGeometry.clampedOrigin(once, for: .small, onVisible: main.visibleFrame)
        check(once == twice, "clamping is idempotent (got \(once) then \(twice))")
    }

    // MARK: - Undo menu rows

    /// U1: the Undo rows name the record they'd reverse, on a second line.
    /// Pure string work, and it lives beside the records rather than in
    /// PetWindow (not in this check target) precisely so it can be asserted
    /// here.
    static func undoMenuRowChecks() {
        func delivery(_ names: [String]?) -> CourierOperation {
            CourierOperation(date: Date(), isCopy: false, transfers: [], rewrites: [],
                             deliveredNames: names)
        }
        func capture(_ notePath: String) -> CaptureRecord {
            CaptureRecord(date: Date(), vaultPath: "/v", notePath: notePath,
                          appended: "x", createdFile: false)
        }

        check(delivery(["recipe.md"]).undoMenuSubtitle == "recipe.md",
              "one delivered note is named in the row")
        check(delivery(["a.md", "b.md", "c.md"]).undoMenuSubtitle == "3 notes",
              "several notes are counted")
        check(delivery(["a.md", "photo.png"]).undoMenuSubtitle == "2 files",
              "a mixed drop counts files, not notes")
        check(delivery(["photo.png"]).undoMenuSubtitle == "photo.png",
              "a bare attachment drop is named too")

        // Records journaled before deliveredNames existed, and the empty case
        // deliver() can't produce: both draw a plain row rather than naming
        // nothing. Note nil here means "unnamed", not "nothing to undo" —
        // that distinction is UndoRow's, and it's why the row stays enabled.
        check(delivery(nil).undoMenuSubtitle == nil,
              "a record from before names were kept draws a plain row")
        check(delivery([]).undoMenuSubtitle == nil,
              "an empty name list draws a plain row")
        let legacy = #"{"date":"2026-07-01T00:00:00Z","isCopy":false,"rewrites":[],"transfers":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try? decoder.decode(CourierOperation.self, from: Data(legacy.utf8))
        check(old != nil && old?.deliveredNames == nil,
              "a pre-U1 journal line still decodes (no migration)")

        check(capture("/v/2026-07-25.md").undoMenuSubtitle == "2026-07-25.md",
              "capture names its target note")
        check(capture("").undoMenuSubtitle == nil,
              "a capture with no note path draws a plain row")

        // A note name has no length limit; a menu row does.
        let long = String(repeating: "n", count: 80) + ".md"
        let cut = delivery([long]).undoMenuSubtitle
        check(cut == String(repeating: "n", count: UndoName.budget - 1) + "…",
              "an over-long name is cut to the budget")
        check(cut?.count == UndoName.budget, "the cut name is exactly the budget")
        let exact = String(repeating: "n", count: UndoName.budget)
        check(delivery([exact]).undoMenuSubtitle == exact,
              "a name exactly at the budget is left whole")
    }

    // MARK: - Obsidian link parsing

    static func obsidianLinkChecks() {
        // Valid link.
        if let link = ObsidianOpenLink("obsidian://open?vault=MyVault&file=notes/hello") {
            check(link.vaultName == "MyVault", "obsidian link: vault name parses")
            check(link.filePath == "notes/hello", "obsidian link: file path parses")
        } else {
            check(false, "valid obsidian link should parse")
        }

        // Percent-encoded vault name.
        if let link = ObsidianOpenLink("obsidian://open?vault=My%20Vault&file=test") {
            check(link.vaultName == "My Vault", "obsidian link: percent-encoded vault name")
        } else {
            check(false, "percent-encoded obsidian link should parse")
        }

        // Missing vault → nil.
        check(ObsidianOpenLink("obsidian://open?file=notes/hello") == nil,
              "obsidian link: missing vault → nil")

        // Missing file → nil.
        check(ObsidianOpenLink("obsidian://open?vault=V") == nil,
              "obsidian link: missing file → nil")

        // Wrong scheme → nil.
        check(ObsidianOpenLink("https://open?vault=V&file=f") == nil,
              "obsidian link: wrong scheme → nil")

        // Wrong host → nil.
        check(ObsidianOpenLink("obsidian://vault?vault=V&file=f") == nil,
              "obsidian link: wrong host → nil")

        // Traversal in file path parses (containment is checked by caller).
        if let link = ObsidianOpenLink("obsidian://open?vault=V&file=../../../etc/passwd") {
            check(link.filePath == "../../../etc/passwd",
                  "obsidian link: traversal path parses (containment is caller's job)")
        } else {
            check(false, "traversal obsidian link should still parse")
        }

        // Not a URL → nil.
        check(ObsidianOpenLink("not a url") == nil, "obsidian link: garbage → nil")
    }
}
