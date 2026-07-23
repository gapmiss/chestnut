import Foundation

/// One quick-capture append, with everything needed to undo it.
struct CaptureRecord: Codable, Equatable {
    let date: Date
    let vaultPath: String
    let notePath: String
    /// Exact text appended, including any separator newline added in front.
    let appended: String
    /// The note was created by this capture (undo trashes it if unchanged).
    let createdFile: Bool
}

enum CaptureError: LocalizedError {
    case emptyText
    case noteChanged(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            "Nothing to capture."
        case .noteChanged(let path):
            "\((path as NSString).lastPathComponent) no longer ends with the captured text."
        }
    }
}

/// Appends captured text to a vault's daily note (settings read-only from
/// `.obsidian/daily-notes.json`), falling back to an inbox note at the vault
/// root when the daily note can't be determined.
///
/// The `obsidian` CLI is auditioned here per the spec — `daily:append` applies
/// the user's daily-note template on creation, which a direct write can't —
/// but it stays an optional enhancement (hard invariant): every capture works
/// with the CLI absent or Obsidian closed via the direct-FS path.
struct Capture {
    /// File receiving captures when there is no daily note to target.
    let inboxFileName: String
    /// Chestnut-native daily-note format, used when Obsidian's plugin is off.
    let captureFormat: String?
    /// Folder for Chestnut-native daily notes (relative to vault root).
    let captureFolder: String?

    // Computed (not stored) so the struct stays Sendable — captures run off
    // the main actor to keep the CLI's blocking waits from freezing the UI.
    private var fm: FileManager { .default }

    init(inboxFileName: String = "Inbox.md", captureFormat: String? = nil, captureFolder: String? = nil) {
        self.inboxFileName = inboxFileName
        self.captureFormat = captureFormat
        self.captureFolder = captureFolder
    }

    // MARK: - Capture

    /// Append `text` to the vault's daily note (or inbox). Pass `cliVaultName`
    /// only when the CLI can be trusted to target this vault — Obsidian
    /// running, vault open, and the name unique in the registry (the CLI
    /// targets by name; we key vaults by path).
    func capture(
        _ text: String, toVault vault: URL, cliVaultName: String? = nil, date: Date = Date()
    ) throws -> CaptureRecord {
        // Trailing whitespace is ours to normalize (we supply the final
        // newline); leading line-breaks and indentation are the user's
        // spacing — keep them.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.emptyText
        }
        var content = Substring(text)
        while let last = content.last, last.isWhitespace { content = content.dropLast() }
        let trimmed = String(content)
        if let name = cliVaultName, let record = captureViaCLI(trimmed, toVault: vault, vaultName: name) {
            return record
        }
        return try appendDirectly(trimmed, toVault: vault, date: date)
    }

    /// Reverse a journaled capture: notes created by it are trashed (never
    /// deleted) if still untouched; otherwise the appended suffix is removed —
    /// and if the note no longer ends with it, refuse rather than guess.
    func undo(_ record: CaptureRecord) throws {
        let note = URL(fileURLWithPath: record.notePath)
        let data = (try? Data(contentsOf: note)) ?? Data()
        let appended = Data(record.appended.utf8)
        if record.createdFile, data == appended {
            try fm.trashItem(at: note, resultingItemURL: nil)
            return
        }
        guard data.count >= appended.count, data.suffix(appended.count) == appended else {
            throw CaptureError.noteChanged(record.notePath)
        }
        try data.dropLast(appended.count).write(to: note, options: .atomic)
    }

    // MARK: - Direct-FS append

    func appendDirectly(_ text: String, toVault vault: URL, date: Date = Date()) throws -> CaptureRecord {
        let note = destination(inVault: vault, date: date)
        precondition(
            !note.pathComponents.contains(".obsidian"),
            "Capture must never write inside .obsidian/"
        )
        let existing = try? Data(contentsOf: note)
        var appended = text + "\n"
        if let existing, !existing.isEmpty, existing.last != UInt8(ascii: "\n") {
            appended = "\n" + appended
        }
        try fm.createDirectory(
            at: note.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try ((existing ?? Data()) + Data(appended.utf8)).write(to: note, options: .atomic)
        return CaptureRecord(
            date: Date(), vaultPath: vault.path, notePath: note.path,
            appended: appended, createdFile: existing == nil
        )
    }

    /// Today's daily note per the vault's settings, else the inbox at the
    /// vault root. Tries Obsidian's daily-notes plugin first, then Chestnut's
    /// own captureFormat/captureFolder, then the static inbox. Anything
    /// suspicious (escaping the vault, `.obsidian/`) lands on the inbox.
    func destination(inVault vault: URL, date: Date = Date()) -> URL {
        let inbox = vault.appendingPathComponent(inboxFileName)
        if let relative = Self.dailyNoteRelativePath(vault: vault, date: date) {
            let note = vault.appendingPathComponent(relative)
            if !note.pathComponents.contains(".obsidian"),
               note.standardizedFileURL.path.hasPrefix(vault.standardizedFileURL.path + "/") {
                return note
            }
        }
        if let relative = chestnutDailyRelativePath(date: date) {
            let note = vault.appendingPathComponent(relative)
            if !note.pathComponents.contains(".obsidian"),
               note.standardizedFileURL.path.hasPrefix(vault.standardizedFileURL.path + "/") {
                return note
            }
        }
        return inbox
    }

    /// Today's capture target only when it already exists on disk. The Vault
    /// Hopper's "open daily note" goes through here so opening stays
    /// read-only — hopping to a note must never create one.
    func existingDestination(inVault vault: URL, date: Date = Date()) -> URL? {
        let note = destination(inVault: vault, date: date)
        return fm.fileExists(atPath: note.path) ? note : nil
    }

    /// Chestnut-native daily-note path from captureFormat/captureFolder config.
    private func chestnutDailyRelativePath(date: Date) -> String? {
        guard let format = captureFormat, !format.isEmpty else { return nil }
        guard let name = Self.formatDailyPath(format: format, date: date) else { return nil }
        var folder = (captureFolder ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if folder.hasPrefix("./") { folder = String(folder.dropFirst(2)) }
        let relative = folder.isEmpty ? name + ".md" : folder + "/" + name + ".md"
        guard !relative.split(separator: "/").contains("..") else { return nil }
        return relative
    }

    // MARK: - Daily-note settings (read-only peeks at .obsidian/*.json)

    /// Vault-relative path of the daily note for `date`, or nil when the
    /// daily-notes core plugin is disabled or the format uses tokens we
    /// don't render (then we can't match Obsidian's file name).
    static func dailyNoteRelativePath(vault: URL, date: Date) -> String? {
        guard dailyNotesEnabled(vault: vault) else { return nil }
        var format = "YYYY-MM-DD"  // Obsidian's defaults
        var folder = ""
        if let data = try? Data(contentsOf: vault.appendingPathComponent(".obsidian/daily-notes.json")),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let f = dict["format"] as? String, !f.isEmpty { format = f }
            if let f = dict["folder"] as? String { folder = f }
        }
        guard let name = formatDailyPath(format: format, date: date) else { return nil }
        if folder.hasPrefix("./") { folder = String(folder.dropFirst(2)) }
        folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative = folder.isEmpty ? name + ".md" : folder + "/" + name + ".md"
        guard !relative.split(separator: "/").contains("..") else { return nil }
        return relative
    }

    /// The daily-notes core plugin ships enabled; only an explicit opt-out in
    /// `core-plugins.json` disables it. Both historical formats appear in the
    /// wild: the newer `{"daily-notes": bool}` dict and the older array of
    /// enabled plugin ids.
    static func dailyNotesEnabled(vault: URL) -> Bool {
        guard let data = try? Data(contentsOf: vault.appendingPathComponent(".obsidian/core-plugins.json")),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return true }
        if let dict = json as? [String: Any] {
            return dict["daily-notes"] as? Bool ?? true
        }
        if let list = json as? [String] {
            return list.contains("daily-notes")
        }
        return true
    }

    /// Render a Moment.js date format with the token subset daily notes
    /// commonly use — YYYY YY MM M DD D, `[bracketed]` literals, and
    /// punctuation passed through (including `/`: folders inside the format
    /// are an Obsidian idiom). Any other letter run → nil (unsupported).
    static func formatDailyPath(format: String, date: Date) -> String? {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }
        var out = ""
        var index = format.startIndex
        while index < format.endIndex {
            let ch = format[index]
            if ch == "[" {  // literal until the closing bracket
                guard let close = format[index...].firstIndex(of: "]") else { return nil }
                out += format[format.index(after: index)..<close]
                index = format.index(after: close)
            } else if ch.isLetter {
                let runStart = index
                while index < format.endIndex, format[index] == ch {
                    index = format.index(after: index)
                }
                switch format[runStart..<index] {
                case "YYYY": out += String(format: "%04d", year)
                case "YY": out += String(format: "%02d", year % 100)
                case "MM": out += String(format: "%02d", month)
                case "M": out += String(month)
                case "DD": out += String(format: "%02d", day)
                case "D": out += String(day)
                default: return nil
                }
            } else {
                out.append(ch)
                index = format.index(after: index)
            }
        }
        return out
    }

    // MARK: - CLI (optional enhancement)

    /// Ask the CLI for the daily note's path, then `daily:append`. Returns nil
    /// whenever the direct-FS path should run instead — CLI missing, errored,
    /// or the note verifiably unchanged. Once the file *has* changed we always
    /// return a record (falling back then would append twice).
    private func captureViaCLI(_ text: String, toVault vault: URL, vaultName: String) -> CaptureRecord? {
        guard ObsidianCLI.url != nil,
              !text.contains("\\"),  // the CLI unescapes \n/\t; don't risk mangling
              let rawPath = runCLI(["daily:path", "vault=\(vaultName)"])?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty, !rawPath.hasPrefix("/")
        else { return nil }

        let note = vault.appendingPathComponent(rawPath)
        // The CLI targets by *name*. The caller only passes unique names, but
        // verify the path lands in the expected vault before writing anything.
        guard !note.pathComponents.contains(".obsidian"),
              note.standardizedFileURL.path.hasPrefix(vault.standardizedFileURL.path + "/")
        else { return nil }

        let before = try? Data(contentsOf: note)
        let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
        _ = runCLI(["daily:append", "vault=\(vaultName)", "content=\(escaped)"])
        guard let after = try? Data(contentsOf: note), after != before else {
            return nil  // nothing was written; safe to append directly
        }

        // Best effort: recover the exact appended bytes so undo can trim them.
        // A template applied on creation breaks the prefix match; then the
        // record keeps the raw text and undo's suffix check still protects us.
        var appended = text + "\n"
        let beforeData = before ?? Data()
        if after.count > beforeData.count, after.prefix(beforeData.count) == beforeData,
           let suffix = String(data: Data(after.dropFirst(beforeData.count)), encoding: .utf8) {
            appended = suffix
        }
        return CaptureRecord(
            date: Date(), vaultPath: vault.path, notePath: note.path,
            appended: appended, createdFile: before == nil
        )
    }

    /// Run the CLI with a hard timeout (it talks to the live app and can
    /// hang without it). Returns trimmed stdout on success; nil on failure,
    /// timeout, or an "Error:" reply.
    private func runCLI(_ arguments: [String], timeout: TimeInterval = 3) -> String? {
        ObsidianCLI.run(arguments, timeout: timeout)
    }
}
