import Foundation

/// Timestamp for the debug log and for `CHESTNUT_TIMESTAMP`. A value-type
/// format style rather than a shared `ISO8601DateFormatter`: the two callers
/// sit on different executors (`DebugLog.log` is `@MainActor`,
/// `PluginRunner.environment` is `nonisolated`), so a shared instance needed
/// `nonisolated(unsafe)` — a promise of thread-safety that Foundation
/// documents for `NSDateFormatter` but *not* for `ISO8601DateFormatter`.
/// `Date.ISO8601FormatStyle` is `Sendable` with no shared state, so the
/// promise isn't needed. Output is byte-identical to the formatter's default
/// (`.withInternetDateTime`), which matters: `CHESTNUT_TIMESTAMP` is
/// documented plugin API.
func iso8601Timestamp(_ date: Date = Date()) -> String {
    date.formatted(.iso8601)
}

/// Names the files a log line is about, capped so one drop can't dominate the
/// log. Names rather than full paths: `AppDelegate` already logs every
/// `from → to` pair once a delivery completes, and the gap this fills is the
/// drop the user *cancels* at the destination palette, where the only question
/// is which items the courier was handed. Pure and in the check target, since
/// `PetWindow.swift` is not.
func debugFileList(_ urls: [URL], cap: Int = 10) -> String {
    let names = urls.prefix(cap).map(\.lastPathComponent).joined(separator: ", ")
    guard urls.count > cap else { return names }
    return names + ", +\(urls.count - cap) more"
}

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
        let ts = iso8601Timestamp()
        let line = "\(ts) \(message)\n"
        handle.write(Data(line.utf8))
    }
}
