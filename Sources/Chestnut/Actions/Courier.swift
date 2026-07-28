import Foundation

/// One completed delivery, with everything needed to undo it.
struct CourierOperation: Codable, Equatable {
    struct FileTransfer: Codable, Equatable {
        let from: String
        let to: String
        /// True when `to` already existed with identical content and the move
        /// just removed the redundant source — undo copies back instead of
        /// taking the destination's file.
        let dedup: Bool
    }
    /// A note whose link targets were updated during delivery; `original` is
    /// the pre-rewrite content, restored on undo.
    struct NoteRewrite: Codable, Equatable {
        let notePath: String   // destination path at time of delivery
        let original: String
    }

    let date: Date
    let isCopy: Bool
    let transfers: [FileTransfer]
    let rewrites: [NoteRewrite]
    /// What the user dropped, by source file name, so the Undo row can say
    /// which delivery it takes back. Source names rather than delivered ones:
    /// a conflict suffix (" 1") is Chestnut's bookkeeping, not what the user
    /// recognises. `transfers` can't answer this — attachments are placed
    /// before their note and several notes interleave. Nil in records
    /// journaled before the menu named anything.
    var deliveredNames: [String]?
}

extension CourierOperation {
    /// Second line for the Undo row that reverses this delivery. Undo walks
    /// back through history one record per click, so an unnamed row leaves the
    /// user firing blind from the second click on. Nil for records journaled
    /// before `deliveredNames`.
    var undoMenuSubtitle: String? {
        guard let names = deliveredNames, !names.isEmpty else { return nil }
        if names.count == 1 { return UndoName.cut(names[0]) }
        let allNotes = names.allSatisfy { ($0 as NSString).pathExtension.lowercased() == "md" }
        return "\(names.count) \(allNotes ? "notes" : "files")"
    }
}

enum CourierError: LocalizedError {
    case nothingToDeliver
    case destinationIsSource
    /// A note whose text can't be decoded. Refused rather than delivered:
    /// without the text there is no way to know which attachments the note
    /// embeds, and moving it alone strands them in the source vault with the
    /// operation still reporting success. See `deliverNote`.
    case unreadableNote(name: String, reason: String)
    /// Undo reversed what it could and could not reverse the rest. Carries
    /// enough to tell the user which files stayed put — the state is known,
    /// not a mystery, so the message says so rather than "undo failed".
    case partiallyUndone(restored: Int, unreachable: [String])

    var errorDescription: String? {
        switch self {
        case .nothingToDeliver: return "No files to deliver."
        case .destinationIsSource: return "The note is already in that vault."
        case let .unreadableNote(name, reason):
            // No promise that nothing moved: rollback is best-effort, and a
            // multi-file drop may have placed earlier files already.
            return "Couldn't read \(name) as text, so Chestnut can't tell which "
                + "attachments it needs. The delivery was cancelled rather than "
                + "move the note and leave them behind. (\(reason))"
        case let .partiallyUndone(restored, unreachable):
            let shown = unreachable.prefix(3).joined(separator: ", ")
            let rest = unreachable.count > 3 ? " and \(unreachable.count - 3) more" : ""
            let brought = restored == 0
                ? "Nothing could be brought back."
                : "Brought back \(restored) file\(restored == 1 ? "" : "s")."
            return "\(brought) Chestnut couldn't restore \(shown)\(rest) — "
                + "no longer where the delivery left \(unreachable.count == 1 ? "it" : "them"), "
                + "or couldn't be moved back."
        }
    }
}

/// Moves or copies notes — and the attachments they embed — between vaults.
///
/// Hard rules (see CLAUDE.md): never overwrite anything (conflicts get
/// Obsidian-style " 1" suffixes), and never write inside `.obsidian/`.
/// The only files modified are the delivered notes themselves, when their
/// references must change to keep resolving; originals are journaled.
struct Courier {
    // Computed (not stored) so the struct stays Sendable — deliveries run off
    // the main actor to keep byte copies and vault walks from freezing the UI.
    private var fm: FileManager { .default }

    // MARK: - Delivery

    /// Move (or copy) `files` into `destVault`. `.md` files land at the vault
    /// root and bring their referenced attachments; other files land in the
    /// vault's attachment folder. `sourceVault` scopes attachment resolution;
    /// pass nil for files dragged from outside any known vault.
    func deliver(
        files: [URL], toVault destVault: URL, sourceVault: URL?, copy: Bool
    ) throws -> CourierOperation {
        guard !files.isEmpty else { throw CourierError.nothingToDeliver }
        if let sourceVault, sourceVault.standardizedFileURL == destVault.standardizedFileURL {
            throw CourierError.destinationIsSource
        }

        let attachmentDir = attachmentFolder(of: destVault)
        var transfers: [CourierOperation.FileTransfer] = []
        var rewrites: [CourierOperation.NoteRewrite] = []
        // source path → final destination, so two notes sharing an attachment
        // don't try to move it twice.
        var placed: [String: URL] = [:]

        do {
            for file in files {
                if file.pathExtension.lowercased() == "md" {
                    try deliverNote(
                        file, destVault: destVault, attachmentDir: attachmentDir,
                        sourceVault: sourceVault, copy: copy,
                        transfers: &transfers, rewrites: &rewrites, placed: &placed
                    )
                } else {
                    try transfer(file, into: attachmentDir, copy: copy,
                                 transfers: &transfers, placed: &placed)
                }
            }
        } catch {
            rollback(transfers, copy: copy)
            throw error
        }

        return CourierOperation(
            date: Date(), isCopy: copy, transfers: transfers, rewrites: rewrites,
            deliveredNames: files.map(\.lastPathComponent)
        )
    }

    /// Reverse a journaled delivery: moves go back (content restored where
    /// references were rewritten); copies are moved to the Trash, never deleted.
    ///
    /// Every transfer is attempted exactly once, and one that fails does not
    /// stop the ones behind it. The common failure is a delivered file the
    /// user has since deleted or renamed in Obsidian, and hard-stopping on it
    /// stranded every remaining transfer half-reversed, with nothing saying
    /// which. Reversing all that can be reversed leaves a *known* state, and
    /// `partiallyUndone` names the rest. The record is spent either way — a
    /// second undo can only re-fail on the transfers already reversed — so
    /// this throws rather than returning quietly.
    func undo(_ op: CourierOperation) throws {
        var unreachable: [String] = []

        if op.isCopy {
            for t in op.transfers.reversed() {
                let url = URL(fileURLWithPath: t.to)
                // A copy that is already gone is not a failure: there is no
                // copy left to take back.
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    unreachable.append(url.lastPathComponent)
                }
            }
            try reportIfIncomplete(unreachable, of: op)
            return
        }

        let originalByPath = Dictionary(
            op.rewrites.map { ($0.notePath, $0.original) },
            uniquingKeysWith: { first, _ in first }
        )
        for t in op.transfers.reversed() {
            let delivered = URL(fileURLWithPath: t.to)
            guard fm.fileExists(atPath: delivered.path) else {
                unreachable.append(delivered.lastPathComponent)
                continue
            }
            do {
                let home = availableURL(for: URL(fileURLWithPath: t.from))
                try fm.createDirectory(
                    at: home.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if t.dedup {
                    try fm.copyItem(at: delivered, to: home)
                } else {
                    try fm.moveItem(at: delivered, to: home)
                }
                if let original = originalByPath[t.to] {
                    try original.write(to: home, atomically: true, encoding: .utf8)
                }
            } catch {
                unreachable.append(delivered.lastPathComponent)
            }
        }
        try reportIfIncomplete(unreachable, of: op)
    }

    private func reportIfIncomplete(
        _ unreachable: [String], of op: CourierOperation
    ) throws {
        guard !unreachable.isEmpty else { return }
        throw CourierError.partiallyUndone(
            restored: op.transfers.count - unreachable.count, unreachable: unreachable
        )
    }

    // MARK: - Notes & attachments

    private func deliverNote(
        _ note: URL, destVault: URL, attachmentDir: URL, sourceVault: URL?,
        copy: Bool,
        transfers: inout [CourierOperation.FileTransfer],
        rewrites: inout [CourierOperation.NoteRewrite],
        placed: inout [String: URL]
    ) throws {
        // Bind the error rather than coercing it to "". An empty note resolves
        // no references, so the coercion delivered the note alone, journaled
        // no rewrite, and reported success — the attachments stayed in the
        // source vault and nothing said so. The read fails for a dataless
        // iCloud placeholder as readily as for a non-UTF-8 file, so this is
        // reachable without any exotic encoding. Refusing costs nothing extra:
        // deliver's catch already rolls back and rethrows.
        let content: String
        do {
            content = try String(contentsOf: note, encoding: .utf8)
        } catch {
            throw CourierError.unreadableNote(
                name: note.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        let searchRoot = sourceVault ?? note.deletingLastPathComponent()

        // Resolve and place attachments first, so the note can be rewritten
        // to their final names before it moves.
        var rewritten = content
        for reference in Self.references(in: content) {
            // Notes are never carried as attachments: other source-vault
            // notes may link to them, and a real note move would have to
            // recurse into *their* embeds. Obsidian omits ".md" in note
            // embeds so they normally don't resolve anyway; this guard keeps
            // an explicit "![[Note.md]]" out of the attachment folder too.
            if reference.target.lowercased().hasSuffix(".md") { continue }
            // `placed` is keyed by source path *and* reference target, so a
            // second note sharing an attachment finds it even after the move.
            let destination: URL
            if let known = placed[reference.target] {
                destination = known
            } else if let source = resolve(
                reference.target, in: searchRoot, noteDir: note.deletingLastPathComponent()
            ) {
                destination = try placed[source.path]
                    ?? place(source, into: attachmentDir, copy: copy, transfers: &transfers)
                placed[source.path] = destination
                placed[reference.target] = destination
            } else {
                continue
            }
            rewritten = Self.rewrite(
                reference, in: rewritten,
                newName: destination.lastPathComponent,
                pathRelativeToNoteDir: relativePath(of: destination, fromDir: destVault)
            )
        }

        let noteDest = try place(note, into: destVault, copy: copy, transfers: &transfers)
        placed[note.path] = noteDest
        if rewritten != content {
            try rewritten.write(to: noteDest, atomically: true, encoding: .utf8)
            rewrites.append(.init(notePath: noteDest.path, original: content))
        }
    }

    private func transfer(
        _ file: URL, into dir: URL, copy: Bool,
        transfers: inout [CourierOperation.FileTransfer],
        placed: inout [String: URL]
    ) throws {
        guard placed[file.path] == nil else { return }
        placed[file.path] = try place(file, into: dir, copy: copy, transfers: &transfers)
    }

    /// Move/copy one file into `dir` under a conflict-free name. If the same
    /// content already exists there under the same name, reuse it (no-op for
    /// copies; moves remove the now-redundant source).
    private func place(
        _ source: URL, into dir: URL, copy: Bool,
        transfers: inout [CourierOperation.FileTransfer]
    ) throws -> URL {
        precondition(
            !dir.pathComponents.contains(".obsidian"),
            "Courier must never write inside .obsidian/"
        )
        let desired = dir.appendingPathComponent(source.lastPathComponent)
        if Self.isSameFile(source, desired) {
            // Delivering a file onto itself — reachable when obsidian.json
            // lists one vault under two spellings, one through a symlink, so
            // the standardizedFileURL comparison in `deliver` doesn't catch
            // it. The dedup branch below would read the "existing copy" as
            // redundant and delete the only copy.
            return desired
        }
        if fm.fileExists(atPath: desired.path), contentsEqual(source, desired) {
            // Same bytes already there: copies have nothing to do; moves just
            // drop the redundant source (recorded so undo can copy it back).
            if !copy {
                try fm.removeItem(at: source)
                transfers.append(.init(from: source.path, to: desired.path, dedup: true))
            }
            return desired
        }
        let destination = availableURL(for: desired)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if copy {
            try fm.copyItem(at: source, to: destination)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
        transfers.append(.init(from: source.path, to: destination.path, dedup: false))
        return destination
    }

    /// Best-effort reversal after a mid-delivery failure.
    private func rollback(_ transfers: [CourierOperation.FileTransfer], copy: Bool) {
        for t in transfers.reversed() {
            if copy {
                try? fm.removeItem(atPath: t.to)
            } else if !fm.fileExists(atPath: t.from) {
                if t.dedup {
                    try? fm.copyItem(atPath: t.to, toPath: t.from)
                } else {
                    try? fm.moveItem(atPath: t.to, toPath: t.from)
                }
            }
        }
    }

    // MARK: - Reference parsing & rewriting

    struct Reference: Equatable {
        let raw: String       // exact substring to replace, e.g. "![[img.png|200]]"
        let target: String    // decoded target, e.g. "img.png" or "assets/img.png"
        let isWikilink: Bool
    }

    /// Embedded-file references in a note: `![[target|…]]` and `![alt](path)`.
    /// External URLs are ignored.
    static func references(in content: String) -> [Reference] {
        // Inline literals: Regex isn't Sendable, so it can't be a static let.
        // The wikilink target scans non-greedily to the first `]]` (not the
        // first `]`) because filenames may contain single brackets — yt-dlp's
        // "name [videoID].webm" is common — and Obsidian embeds them fine.
        let wikilinkPattern = #/!\[\[(.+?)\]\]/#
        let markdownPattern = #/!\[[^\]]*\]\(([^)]+)\)/#
        var refs: [Reference] = []
        for match in content.matches(of: wikilinkPattern) {
            // Target ends at the first `|` (display size) or `#` (subpath).
            let inner = String(match.1)
            let target = String(inner.prefix { $0 != "|" && $0 != "#" })
                .trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            refs.append(.init(raw: String(match.0), target: target, isWikilink: true))
        }
        for match in content.matches(of: markdownPattern) {
            let rawPath = String(match.1)
            guard !rawPath.contains("://") else { continue }
            let target = rawPath.removingPercentEncoding ?? rawPath
            refs.append(.init(raw: String(match.0), target: target, isWikilink: false))
        }
        return refs
    }

    /// Update one reference so it resolves after delivery: wikilinks point at
    /// the (possibly renamed) basename; markdown links get the new relative path.
    static func rewrite(
        _ reference: Reference, in content: String,
        newName: String, pathRelativeToNoteDir: String
    ) -> String {
        let newRaw: String
        if reference.isWikilink {
            let oldTarget = reference.target
            let inner = reference.raw.dropFirst(3).dropLast(2)  // strip "![[", "]]"
            let newInner = inner.replacingOccurrences(
                of: oldTarget, with: newName.hasSuffix(".md")
                    ? String(newName.dropLast(3)) : newName
            )
            newRaw = "![[\(newInner)]]"
        } else {
            let encoded = pathRelativeToNoteDir.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? pathRelativeToNoteDir
            // Replace only the (path) portion of the exact match.
            guard let open = reference.raw.lastIndex(of: "(") else { return content }
            newRaw = reference.raw[..<open] + "(" + encoded + ")"
        }
        return content.replacingOccurrences(of: reference.raw, with: newRaw)
    }

    // MARK: - Resolution helpers

    /// Find a referenced file: exact vault-relative (or note-relative) path
    /// first, then Obsidian-style by filename anywhere in the vault.
    /// Targets come from note content, so anything resolving outside the
    /// search root (`../…`, absolute paths) is refused — the courier must
    /// never move or copy files it doesn't own.
    private func resolve(_ target: String, in vaultRoot: URL, noteDir: URL) -> URL? {
        let rootPrefix = vaultRoot.standardizedFileURL.path + "/"
        for base in [vaultRoot, noteDir] {
            let candidate = base.appendingPathComponent(target)
            guard candidate.standardizedFileURL.path.hasPrefix(rootPrefix) else { continue }
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let name = (target as NSString).lastPathComponent
        guard let walker = fm.enumerator(
            at: vaultRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    /// Destination vault's attachment folder, per its `.obsidian/app.json`.
    /// `""`/`"/"` (or anything that would land in `.obsidian/` or escape the
    /// vault, like `"../shared"`) → vault root;
    /// `"./x"` → relative to the note (notes land at the root, so also root-based).
    func attachmentFolder(of vault: URL) -> URL {
        let appJSON = vault.appendingPathComponent(".obsidian/app.json")
        guard
            let data = try? Data(contentsOf: appJSON),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var setting = dict["attachmentFolderPath"] as? String
        else { return vault }

        if setting.hasPrefix("./") { setting = String(setting.dropFirst(2)) }
        setting = setting.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !setting.isEmpty else { return vault }
        let dir = vault.appendingPathComponent(setting)
        guard !dir.pathComponents.contains(".obsidian"),
              dir.standardizedFileURL.path.hasPrefix(vault.standardizedFileURL.path + "/")
        else { return vault }
        return dir
    }

    /// First non-existing variant of `desired`: `name.ext`, `name 1.ext`, …
    static func availableURL(
        for desired: URL, using fm: FileManager = .default
    ) -> URL {
        guard fm.fileExists(atPath: desired.path) else { return desired }
        let dir = desired.deletingLastPathComponent()
        let ext = desired.pathExtension
        let base = desired.deletingPathExtension().lastPathComponent
        for n in 1... {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        fatalError("unreachable")
    }

    private func availableURL(for desired: URL) -> URL {
        Self.availableURL(for: desired, using: fm)
    }

    private func contentsEqual(_ a: URL, _ b: URL) -> Bool {
        fm.contentsEqual(atPath: a.path, andPath: b.path)
    }

    /// Whether two paths name the same file-system object (resolves symlinks
    /// and hard links via the volume/inode identifier). This is a read-side
    /// identity check for the dedup branch in `place` — vault *containment*
    /// is a different question and deliberately stays lexical (see CLAUDE.md).
    /// False when either path doesn't exist.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        guard
            let ia = try? a.resourceValues(
                forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
            let ib = try? b.resourceValues(
                forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return ia.isEqual(ib)
    }

    private func relativePath(of file: URL, fromDir dir: URL) -> String {
        let fileComponents = file.standardizedFileURL.pathComponents
        let dirComponents = dir.standardizedFileURL.pathComponents
        var common = 0
        while common < min(fileComponents.count, dirComponents.count),
              fileComponents[common] == dirComponents[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: dirComponents.count - common)
        return (ups + fileComponents[common...]).joined(separator: "/")
    }

    static func isContained(_ url: URL, inVault vaultPath: String) -> Bool {
        let vaultStd = URL(fileURLWithPath: vaultPath).standardizedFileURL
        let fileStd = url.standardizedFileURL
        return fileStd.path.hasPrefix(vaultStd.path + "/")
            && !fileStd.pathComponents.contains(".obsidian")
    }

    /// Directory variant of `isContained`, which the vault root itself fails:
    /// the prefix test needs a trailing `/`, and no *file* is ever written at
    /// the root path itself, so rejecting it there is correct. A *directory*
    /// argument is different — the root is where a plugin save with no
    /// `folder` lands, and where `attachmentFolder(of:)` falls back when
    /// `attachmentFolderPath` is unset. Both are ordinary, so a caller
    /// checking directories must accept the root or refuse every normal save.
    static func isContainedDirectory(_ url: URL, inVault vaultPath: String) -> Bool {
        let vaultStd = URL(fileURLWithPath: vaultPath).standardizedFileURL
        let dirStd = url.standardizedFileURL
        guard !dirStd.pathComponents.contains(".obsidian") else { return false }
        return dirStd.path == vaultStd.path
            || dirStd.path.hasPrefix(vaultStd.path + "/")
    }
}
