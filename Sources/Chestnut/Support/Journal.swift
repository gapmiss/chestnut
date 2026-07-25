import Foundation

/// Persistent record of Chestnut's writes: one JSON object per line, newest last,
/// in ~/Library/Application Support/Chestnut/. Storage only — the actual undo
/// file operations live with each record's engine (`Courier.undo`,
/// `Capture.undo`). One file per record type, so the logs stay decodable.
struct Journal<Record: Codable> {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Journal files live beside the config.
    static func fileURL(named name: String) -> URL {
        Config.fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    func append(_ record: Record) throws {
        let line = try JournalCoding.encoder.encode(record)
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
        lines().last.flatMap { try? JournalCoding.decoder.decode(Record.self, from: $0) }
    }

    /// Drop the most recent record (after its undo succeeded).
    func removeLast() throws {
        var remaining = lines()
        guard !remaining.isEmpty else { return }
        remaining.removeLast()
        try Self.write(remaining, to: fileURL)
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
/// did": the menu names no particular record, and a record that refuses to
/// reverse is kept and blocks everything older than it, so depth past a
/// handful is unreachable in practice. Keeping less also means less of the
/// user's note text sitting in Application Support.
enum JournalLimits {
    static let maxRecords = 20
    static let maxBytes = 1_000_000
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
