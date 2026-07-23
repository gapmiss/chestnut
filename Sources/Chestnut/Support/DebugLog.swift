import Foundation

nonisolated(unsafe) let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()

@MainActor
enum DebugLog {
    private(set) static var enabled = false
    private static var handle: FileHandle?

    static func configure(enabled flag: Bool) {
        enabled = flag
        guard flag else { return }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Chestnut")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let logURL = dir.appendingPathComponent("chestnut.log")
        let prevURL = dir.appendingPathComponent("chestnut.log.1")
        let fm = FileManager.default

        if fm.fileExists(atPath: logURL.path),
           let attrs = try? fm.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64, size > 1_048_576 {
            try? fm.removeItem(at: prevURL)
            try? fm.moveItem(at: logURL, to: prevURL)
        }

        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logURL)
        handle?.seekToEndOfFile()

        fputs("chestnut: debug log at \(logURL.path)\n", stderr)
        log("--- session start ---")
    }

    static func log(_ message: String) {
        guard enabled, let handle else { return }
        let ts = iso8601.string(from: Date())
        let line = "\(ts) \(message)\n"
        handle.write(Data(line.utf8))
    }
}
