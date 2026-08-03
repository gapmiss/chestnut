import Foundation

/// One `save`-mode plugin write, with everything needed to undo it.
///
/// This is the only write path Chestnut performs that went unjournaled: a
/// courier delivery and a quick capture both leave an undo record, but a
/// plugin returning `output: "save"` wrote a note (and copied its attachments)
/// into a vault with no way to take it back.
///
/// The record holds *paths only*. That is what makes `sheddingPayload` able to
/// return nothing to shed: there is no copy of the note's text here, so unlike
/// `CourierOperation.original` there is nothing large to give up, and unlike
/// `CaptureRecord.appended` there is nothing whose loss would leave a record
/// that reverses the wrong bytes.
struct PluginSaveRecord: Codable, Equatable {
    let date: Date
    /// Names the row's second line. The plugin may since have been deleted;
    /// this is display text, never used to look anything up.
    let pluginName: String
    let vaultPath: String
    let notePath: String
    /// UTF-8 length of the note as written, so undo can tell "the file we
    /// created" from "a different file that now sits at that path".
    let noteBytes: Int
    /// Where the save's attachments landed, so undo can trash them too.
    /// Nil when the save had none.
    var attachmentPaths: [String]?
}

extension PluginSaveRecord: JournalShedding {
    /// Nothing to shed, for the opposite reason to `CaptureRecord`'s: not
    /// because the payload is what makes the record reversible, but because
    /// there is no payload at all. A list of paths cannot meaningfully exceed
    /// the byte cap, and dropping any of it would strand files in the vault.
    func sheddingPayload() -> PluginSaveRecord? { nil }
}

extension PluginSaveRecord {
    /// Second line for the Undo row — see `CourierOperation.undoMenuSubtitle`
    /// for why the row names its record rather than relying on a fixed title.
    ///
    /// The plugin's name rather than the note's, which is the one place this
    /// row departs from its two siblings. A delivery and a capture are things
    /// the user performed on a note they chose; a plugin save is a note the
    /// user never named, produced by a tool they did choose. "Transcribe" says
    /// more about what is being reversed than "Untitled.md" does.
    var undoMenuSubtitle: String? {
        pluginName.isEmpty ? nil : UndoName.cut(pluginName)
    }
}

extension PluginSaveRecord {
    /// Whether the Undo Last Plugin Save row appears at all.
    ///
    /// Its two siblings are always present and merely dim when there is
    /// nothing to reverse, because both name something every user does. This
    /// row names something a user without plugins cannot have done, and it
    /// teaches nothing by sitting there greyed out — the Plugins submenu is
    /// already the place the feature is discovered, and it stays visible with
    /// a "No plugins installed" row of its own. So a fresh install gets two
    /// undo rows, not three.
    ///
    /// The `hasRecord` half is not redundant with the enabled state, and
    /// leaving it out is the trap this whole rule exists to avoid: install a
    /// plugin, let it save a note into a vault, then delete the plugin folder,
    /// and a rule keyed only on `pluginsInstalled` would hide a row that still
    /// has real files to take back. The row can never hide something
    /// reversible.
    ///
    /// `pluginsInstalled` means present on disk, *not* enabled. Toggling a
    /// plugin off in the menu must not make its undo unreachable.
    static func showsUndoRow(pluginsInstalled: Bool, hasRecord: Bool) -> Bool {
        pluginsInstalled || hasRecord
    }
}

enum PluginSaveError: LocalizedError {
    case noteChanged(String)

    var errorDescription: String? {
        switch self {
        case .noteChanged(let path):
            "\((path as NSString).lastPathComponent) is not the file the plugin wrote — it has been edited or replaced."
        }
    }
}

/// Reverses a journaled plugin save. Storage lives in `Journal`; the file
/// operations live here, matching `Courier.undo` and `Capture.undo`.
struct PluginSave {
    private var fm: FileManager { .default }

    /// Trash every file the save created, note first, then attachments.
    ///
    /// Trashed, never deleted — like every other undo in the app. Where that
    /// is depends on the vault: `VaultTrash` honors Obsidian's `trashOption`,
    /// so a vault set to `"local"` gets its files back in `<vault>/.trash/`.
    /// A vault set to `"none"` is the one case where "trashed" is a promise
    /// Chestnut keeps and Obsidian would not — that setting is clamped to the
    /// system Trash, so the sentence above stays true and the recoverability
    /// this comment rests on is never given up. That is also
    /// why there is no "did the user edit this note" refusal of the kind
    /// `Capture.undo` makes: capture reverses by truncating bytes off a file in
    /// place, which cannot be taken back, whereas everything here is a file
    /// Chestnut itself created (`Courier.availableURL` guarantees the save
    /// never overwrote anything), so the worst case is a user's edits sitting
    /// recoverably in the Trash.
    ///
    /// The size check guards a different thing entirely: Obsidian moves and
    /// renames files constantly, so the note may be long gone and an unrelated
    /// file may now occupy its path. Trashing *that* would be destroying
    /// something Chestnut never created. A note whose byte count no longer
    /// matches is refused rather than guessed at, which routes the user to the
    /// same Discard Entry escape hatch a failed capture undo offers. A file
    /// that is simply gone is not a failure — there is nothing left to undo
    /// for it, so it is skipped and the attachments still get cleaned up.
    ///
    /// Byte count rather than a hash: an edit that lands on exactly the
    /// original length gets trashed anyway, and recovering it costs one trip
    /// to the Trash. Cheap and honest beats exact here.
    func undo(_ record: PluginSaveRecord) throws {
        // One instance for the whole reversal, so the vault's setting is read
        // once for a note and all its attachments (see `VaultTrash.memo`).
        let trash = VaultTrash()
        let note = URL(fileURLWithPath: record.notePath)
        if let data = try? Data(contentsOf: note) {
            guard data.count == record.noteBytes else {
                throw PluginSaveError.noteChanged(record.notePath)
            }
            try trash.trash(note)
        }
        trashAttachments(of: record, using: trash)
    }

    /// Attachments are trashed once the note is dealt with, so an undo that
    /// refuses leaves every file alone. Where they land follows the vault's
    /// `trashOption` exactly as the note's does. A file that won't trash is
    /// skipped silently, for the same reason `Capture.trashAttachments` skips
    /// one: the note is already reversed by this point, so throwing would
    /// report the whole undo as failed when the part the user asked about
    /// succeeded.
    private func trashAttachments(of record: PluginSaveRecord, using trash: VaultTrash) {
        for path in (record.attachmentPaths ?? []).reversed() {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { continue }
            try? trash.trash(url)
        }
    }
}
