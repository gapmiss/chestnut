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
}

enum CourierError: LocalizedError {
    case nothingToDeliver
    case destinationIsSource

    var errorDescription: String? {
        switch self {
        case .nothingToDeliver: "No files to deliver."
        case .destinationIsSource: "The note is already in that vault."
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
    private let fm = FileManager.default

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
            date: Date(), isCopy: copy, transfers: transfers, rewrites: rewrites
        )
    }

    /// Reverse a journaled delivery: moves go back (content restored where
    /// references were rewritten); copies are moved to the Trash, never deleted.
    func undo(_ op: CourierOperation) throws {
        if op.isCopy {
            for t in op.transfers.reversed() {
                let url = URL(fileURLWithPath: t.to)
                if fm.fileExists(atPath: url.path) {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                }
            }
            return
        }
        let originalByPath = Dictionary(
            op.rewrites.map { ($0.notePath, $0.original) },
            uniquingKeysWith: { first, _ in first }
        )
        for t in op.transfers.reversed() {
            let home = availableURL(for: URL(fileURLWithPath: t.from))
            try fm.createDirectory(
                at: home.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if t.dedup {
                try fm.copyItem(at: URL(fileURLWithPath: t.to), to: home)
            } else {
                try fm.moveItem(at: URL(fileURLWithPath: t.to), to: home)
            }
            if let original = originalByPath[t.to] {
                try original.write(to: home, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Notes & attachments

    private func deliverNote(
        _ note: URL, destVault: URL, attachmentDir: URL, sourceVault: URL?,
        copy: Bool,
        transfers: inout [CourierOperation.FileTransfer],
        rewrites: inout [CourierOperation.NoteRewrite],
        placed: inout [String: URL]
    ) throws {
        let content = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
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
}
