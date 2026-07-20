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
        let line = try JournalCoding.encoder.encode(record) + Data("\n".utf8)
        let fm = FileManager.default
        try fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
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
        var data = Data(remaining.joined(separator: [0x0A]))  // "\n"
        if !data.isEmpty { data.append(0x0A) }
        try data.write(to: fileURL, options: .atomic)
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
