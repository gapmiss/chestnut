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

/// How a drag's pasteboard is split into items, which is the question the
/// union of types printed by `draggingEntered` cannot answer.
///
/// A Finder multi-select arrives as one item *per file*; a Chromium drag
/// (VSCodium, anything Electron) arrives as a single item carrying
/// `public.url`, which holds one URL by definition. Both look alike in a
/// flat type list, and the difference is exactly why a two-file drag out of
/// VSCodium delivered one file. Per-item types make the shape visible without
/// guessing at the source app.
func debugPasteboardItems(_ itemTypes: [[String]], cap: Int = 4) -> String {
    guard !itemTypes.isEmpty else { return "0 items" }
    let shown = itemTypes.prefix(cap).enumerated().map { index, types in
        "[\(index)] \(types.joined(separator: " "))"
    }.joined(separator: " | ")
    guard itemTypes.count > cap else { return "\(itemTypes.count) items: \(shown)" }
    return "\(itemTypes.count) items: \(shown) | +\(itemTypes.count - cap) more"
}

/// The readable text hiding inside an opaque pasteboard payload.
///
/// `org.chromium.web-custom-data` is a Chromium-internal binary format whose
/// layout is theirs to change, so this deliberately does not parse it: it
/// decodes as UTF-16 little-endian (how Chromium stores its strings) and keeps
/// only printable scalars, collapsing everything else to a single space. The
/// point is to see *whether* a payload still contains every dragged path
/// before deciding whether decoding it properly is worth doing. Reading a
/// format this way is fine for a log line and not fine for routing a drop.
func debugPrintableUTF16(_ data: Data, cap: Int = 400) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(data.count / 2)
    var index = data.startIndex
    while index + 1 < data.endIndex {
        units.append(UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
        index += 2
    }
    var out = ""
    var pendingSpace = false
    for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
        // Printable ASCII only: a path is ASCII often enough, and anything
        // wider risks pasting control bytes into the log.
        if scalar.value >= 0x20, scalar.value < 0x7F {
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.unicodeScalars.append(scalar)
        } else {
            pendingSpace = true
        }
        if out.count >= cap { return out + "…" }
    }
    return out
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
