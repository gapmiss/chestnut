import Foundation

/// Where Obsidian sends a file the user deletes, per `trashOption` in the
/// vault's `.obsidian/app.json`.
///
/// An absent or unrecognised value is `system`, which is what every undo did
/// before this type existed — so a vault that never touched the setting keeps
/// behaving exactly as it always has.
enum VaultTrashOption: String {
    /// The macOS Trash.
    case system
    /// A `.trash/` folder at the vault root, which Obsidian's own
    /// "restore from trash" reads.
    case local
    /// Permanent deletion. Read faithfully, but deliberately not honored on
    /// undo — see `VaultTrash.trash(_:)`.
    case none
}

/// The single place every undo removes a file, so all three agree on where it
/// goes.
///
/// Obsidian lets each vault say where deleted files land, and most people who
/// change it point it at `<vault>/.trash/`. Chestnut used to call
/// `FileManager.trashItem` unconditionally, which put undone files in the macOS
/// Trash where those users would not look for them and where Obsidian's own
/// restore-from-trash cannot see them.
///
/// Not routed through the `obsidian` CLI. Its `delete` command *ignores*
/// `trashOption` — tested against a vault set to `"local"`, twice, and both
/// times the file landed in the system Trash while Obsidian's UI sent its own
/// deletions to `<vault>/.trash/`. The CLI is also optional by invariant, so
/// this filesystem implementation would be needed either way.
///
/// Instantiate one per undo call and let it go afterwards: the memo below is
/// only safe for the length of a single reversal.
final class VaultTrash {
    private let fm = FileManager.default

    /// Resolved option per vault root path. A single undo can touch a note plus
    /// fifty attachments in one vault, and re-reading `app.json` for each is
    /// wasted work. Deliberately *not* shared between undos: the user can
    /// change the setting in Obsidian between two of them, and a stale entry
    /// would send files somewhere they did not ask for.
    private var memo: [String: VaultTrashOption] = [:]

    /// Remove `url` the way its own vault asks for.
    ///
    /// `none` is clamped to the system Trash rather than honored, and that is
    /// the one place this departs from matching Obsidian. `trashOption: none`
    /// is the user's choice about files they consciously delete in Obsidian. An
    /// undo is not that — it reverses something Chestnut did, possibly
    /// something the user did not intend in the first place. Every undo in this
    /// app is recoverable, and one that destroyed a note permanently would
    /// leave nothing when the user changed their mind a moment later.
    ///
    /// A file in no vault at all falls back to the system Trash, as does a
    /// `local` move that fails: getting the file out of the vault is the goal,
    /// and the folder it lands in is a preference.
    func trash(_ url: URL) throws {
        guard let vault = Self.vaultRoot(containing: url) else {
            try fm.trashItem(at: url, resultingItemURL: nil)
            return
        }
        let option: VaultTrashOption
        if let cached = memo[vault.path] {
            option = cached
        } else {
            option = Self.trashOption(forVault: vault)
            memo[vault.path] = option
        }
        guard Self.honored(option) == .local else {
            try fm.trashItem(at: url, resultingItemURL: nil)
            return
        }
        do {
            try moveToLocalTrash(url, inVault: vault)
        } catch {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// The `none` clamp, as a value rather than a branch, so a check can state
    /// it directly and `trash(_:)` cannot drift from what that check asserts.
    static func honored(_ option: VaultTrashOption) -> VaultTrashOption {
        option == .none ? .system : option
    }

    /// `.trash/` is a plain dotfolder Obsidian excludes from indexing, so this
    /// is an ordinary move with nothing to register and no requirement that
    /// Obsidian be running. Conflicts go through `Courier.availableURL`, so
    /// undoing two files of the same name gives `note.md` and `note 1.md`
    /// rather than losing the first.
    private func moveToLocalTrash(_ url: URL, inVault vault: URL) throws {
        let dir = vault.appendingPathComponent(".trash")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = Courier.availableURL(
            for: dir.appendingPathComponent(url.lastPathComponent), using: fm
        )
        try fm.moveItem(at: url, to: destination)
    }

    // MARK: - Reading the vault

    /// The nearest ancestor directory of `url` holding an `.obsidian/` folder,
    /// or nil when the file is not inside a vault.
    ///
    /// Derived from the file's own location rather than stored in the undo
    /// record. `CourierOperation` has no vault field — it keeps bare `from` and
    /// `to` paths — and adding one would leave every already-journaled record
    /// unable to say which vault it belongs to. `CaptureRecord` and
    /// `PluginSaveRecord` do carry `vaultPath`, but they come through here too
    /// so there is one answer to this question and the three undos cannot
    /// drift.
    ///
    /// Nearest rather than outermost, because a vault nested inside another
    /// vault has its own `trashOption` and it is the one that governs.
    static func vaultRoot(
        containing url: URL, using fm: FileManager = .default
    ) -> URL? {
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        // Bounded so a path that never reaches "/" — a relative URL, or a
        // symlink loop resolved by standardization — cannot spin forever.
        for _ in 0..<64 {
            guard dir.path != "/" && !dir.path.isEmpty else { return nil }
            var isDirectory: ObjCBool = false
            let marker = dir.appendingPathComponent(".obsidian").path
            if fm.fileExists(atPath: marker, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return dir
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            guard parent.path != dir.path else { return nil }
            dir = parent
        }
        return nil
    }

    /// `trashOption` from the vault's `.obsidian/app.json`. A missing file, an
    /// unparseable one, a missing key and an unrecognised value all read as
    /// `system` — the behavior every undo had before this existed.
    static func trashOption(forVault vault: URL) -> VaultTrashOption {
        let appJSON = vault.appendingPathComponent(".obsidian/app.json")
        guard
            let data = try? Data(contentsOf: appJSON),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = dict["trashOption"] as? String,
            let option = VaultTrashOption(rawValue: raw)
        else { return .system }
        return option
    }
}
