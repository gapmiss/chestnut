import Foundation

/// A record that can give up part of itself when it alone exceeds the byte cap.
///
/// `trimmed` cannot enforce the cap against a single record: it stops at one
/// rather than leave an empty journal, since an empty journal reads as
/// "nothing to undo", disables the row, and takes the Discard Entry escape
/// hatch out of reach with it. So an oversized record is asked to shed its
/// payload instead of being dropped or kept whole.
///
/// The two record types answer differently, and the difference is whether the
/// payload is a *copy* of something or an *instruction*. See each conformance.
protocol JournalShedding {
    /// The same record with its unbounded payload dropped, or nil when the
    /// payload is what makes the record reversible and shedding would leave a
    /// record that undoes nothing.
    func sheddingPayload() -> Self?
}

/// Persistent record of Chestnut's writes: one JSON object per line, newest last,
/// in ~/Library/Application Support/Chestnut/. Storage only — the actual undo
/// file operations live with each record's engine (`Courier.undo`,
/// `Capture.undo`). One file per record type, so the logs stay decodable.
struct Journal<Record: Codable & JournalShedding> {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Journal files live beside the config.
    static func fileURL(named name: String) -> URL {
        Config.fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    func append(_ record: Record) throws {
        var line = try JournalCoding.encoder.encode(record)
        // A record that blows the cap on its own survives `trimmed` at full
        // size, so the ceiling is enforced here instead — before the line is
        // ever written, not after. Only shed if it actually helps: a record
        // that is large for some other reason (thousands of transfers) has
        // nothing useful to give up and is kept whole rather than mangled.
        if line.count >= JournalLimits.maxBytes,
           let shed = record.sheddingPayload(),
           let shedLine = try? JournalCoding.encoder.encode(shed),
           shedLine.count < line.count {
            line = shedLine
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Rewritten whole rather than seek-and-append: it's how the cap gets
        // enforced, it keeps every write atomic (no half-line survives a crash
        // or a full disk), and a capped file is a few KB, written once per
        // user-initiated delivery or capture.
        try Self.write(Self.trimmed(lines() + [line]), to: fileURL)
    }

    /// Drops the oldest records past the cap. Both limits earn their place:
    /// the count bounds how far back the stack goes, and the byte ceiling
    /// catches the case the count can't, since a single delivery can journal
    /// an entire note body in `NoteRewrite.original`.
    ///
    /// The `count > 1` floor means this can never bind a single oversized
    /// record — deliberately, since an empty journal is worse than a large
    /// one. That gap is closed in `append` by `JournalShedding`, not here.
    private static func trimmed(_ records: [Data]) -> [Data] {
        var kept = Array(records.suffix(JournalLimits.maxRecords))
        while kept.count > 1,
              kept.reduce(0, { $0 + $1.count + 1 }) > JournalLimits.maxBytes {
            kept.removeFirst()
        }
        return kept
    }

    private static func write(_ records: [Data], to url: URL) throws {
        var data = Data(records.joined(separator: [0x0A]))  // "\n"
        if !data.isEmpty { data.append(0x0A) }
        try data.write(to: url, options: .atomic)
    }

    /// The most recent record, if any (undo candidate).
    func last() -> Record? {
        let lines = lines()
        return topIndex(lines).flatMap {
            try? JournalCoding.decoder.decode(Record.self, from: lines[$0])
        }
    }

    /// Drop the most recent record (after its undo succeeded), along with any
    /// unreadable lines sitting on top of it — the file is rewritten whole
    /// anyway, so the sweep is free.
    func removeLast() throws {
        let lines = lines()
        guard let top = topIndex(lines) else { return }
        try Self.write(Array(lines[..<top]), to: fileURL)
    }

    /// Index of the newest line that still decodes.
    ///
    /// Appends are whole-file atomic writes, so this build cannot leave a
    /// half-written line — but every journal on disk today was written by a
    /// build that appended in place, where a crash could. Without the walk, one
    /// torn line makes `last()` nil, which reads as "nothing to undo": the row
    /// disables, and a disabled row can't be clicked, so the Discard Entry
    /// escape hatch can't reach it either. Everything older is stuck for good.
    ///
    /// `last()` and `removeLast()` both resolve the top through here, and that
    /// is the load-bearing part. If one counted records and the other counted
    /// lines, undo would reverse a record that `removeLast` then failed to
    /// remove, and the next click would reverse the same operation a second
    /// time against real files.
    private func topIndex(_ lines: [Data]) -> Int? {
        lines.indices.reversed().first {
            (try? JournalCoding.decoder.decode(Record.self, from: lines[$0])) != nil
        }
    }

    private func lines() -> [Data] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: 0x0A).filter { !$0.isEmpty }
    }
}

extension Journal where Record == CourierOperation {
    /// Courier deliveries — the file name predates capture, kept for old logs.
    static var deliveries: Journal { Journal(fileURL: fileURL(named: "journal.jsonl")) }
}

extension Journal where Record == CaptureRecord {
    static var captures: Journal { Journal(fileURL: fileURL(named: "captures.jsonl")) }
}

/// How much history a journal keeps. Undo serves "take back the thing I just
/// did": a record that refuses to reverse is kept and blocks everything older
/// than it, so depth past a handful is unreachable in practice. Keeping less
/// also means less of the user's note text sitting in Application Support.
enum JournalLimits {
    static let maxRecords = 20
    static let maxBytes = 1_000_000
}

/// One Undo menu row, resolved from the record it would reverse.
///
/// The name goes in `NSMenuItem.subtitle` rather than the title, and that is a
/// width decision, not a style one: `NSMenu` sizes itself to its widest row, so
/// a name in the title made every row as wide as the longest note name — 248pt
/// → 331pt for a 13-character name, 476pt at the old budget. A subtitle is set
/// in a smaller font on its own line and only widens the menu past what the
/// other rows already demand, which measured as 248pt unchanged for names up to
/// ~20 characters and 261pt at the worst case.
struct UndoRow {
    /// Second line naming what would be reversed. Nil for a record journaled
    /// before names were kept, which draws as a plain row.
    let subtitle: String?
}

/// How a journaled record names itself in its Undo row (see
/// `CourierOperation.undoMenuSubtitle`, `CaptureRecord.undoMenuSubtitle`).
/// Shared so the two rows read alike, and here rather than in `PetWindow` so
/// `make check` can reach it.
enum UndoName {
    /// A note name has no length limit and a menu row doesn't wrap. Past this
    /// the name is cut; see `UndoRow` for the widths behind the number.
    static let budget = 24

    static func cut(_ name: String) -> String {
        guard name.count > budget else { return name }
        return name.prefix(budget - 1) + "…"
    }
}

/// Generic types can't hold stored statics; the shared coders live here.
private enum JournalCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]  // single line per record
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
