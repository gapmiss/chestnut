import AppKit
import Foundation

private let pluginImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff",
    "tif", "svg",
]

/// The list of files behind a drag out of a Chromium app — VSCodium, Chrome,
/// anything Electron.
///
/// Chromium never writes `NSFilenamesPboardType`. A multi-file drag arrives as
/// a *single* pasteboard item offering `public.url`, which holds one URL by
/// definition, so through 0.7.0 dragging two files out of VSCodium silently
/// delivered the first and dropped the rest. The full list is still on the
/// pasteboard, in `org.chromium.web-custom-data`: a `base::Pickle` holding the
/// HTML5 `DataTransfer` map the web page set.
///
/// Layout, all integers little-endian, all offsets bounds-checked against the
/// buffer before use:
///
///     uint32  payload byte count (the Pickle header)
///     uint32  number of key/value pairs
///     pair    uint32 length in UTF-16 *code units*, then the UTF-16LE bytes,
///             padded with zeros to the next 4-byte boundary
///
/// Parsing a format Chromium owns is a liability, so every failure returns
/// nothing and the caller keeps whatever AppKit gave it. A wrong answer here
/// would move files the user never dragged, which is why nothing is inferred:
/// a truncated length, a pair count that overruns the buffer, or bytes that
/// are not valid UTF-16 all abandon the parse rather than salvage a prefix.
enum ChromiumCustomData {
    /// The `DataTransfer` map, keyed by MIME type. Empty if anything is off.
    static func decode(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var offset = 0

        func readUInt32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        func readString() -> String? {
            guard let units = readUInt32() else { return nil }
            let byteCount = Int(units) * 2
            // The pad is what the *next* read starts after, so it is part of
            // the bounds check: a string ending flush against the buffer is
            // still well-formed, one whose padding runs past it is not.
            let padded = (byteCount + 3) / 4 * 4
            guard byteCount >= 0, offset + byteCount <= bytes.count,
                  offset + padded <= bytes.count || offset + byteCount == bytes.count
            else { return nil }
            var units16: [UInt16] = []
            units16.reserveCapacity(Int(units))
            for i in stride(from: offset, to: offset + byteCount, by: 2) {
                units16.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            }
            offset += min(padded, bytes.count - offset)
            return String(decoding: units16, as: UTF16.self)
        }

        guard readUInt32() != nil, let pairs = readUInt32() else { return [:] }
        // A pair costs at least 8 bytes (two empty strings), so anything
        // claiming more pairs than the buffer can hold is malformed and not
        // worth allocating for.
        guard Int(pairs) * 8 <= bytes.count - offset else { return [:] }

        var map: [String: String] = [:]
        for _ in 0..<Int(pairs) {
            guard let key = readString(), let value = readString() else { return [:] }
            map[key] = value
        }
        return map
    }

    /// The keys a dragged file list can hide under, in the order they are
    /// trusted. VS Code writes its own vendor type *and* the standard one;
    /// plain web pages write only the standard one.
    static let uriListKeys = ["application/vnd.code.uri-list", "text/uri-list"]

    /// Every existing local file named by the drag, in drag order, without
    /// duplicates.
    ///
    /// Restricted to `file:` URLs on purpose. The same pasteboard key carries
    /// `https:` URLs when the drag came from a web page, and those are the
    /// text plugin's business, not the courier's.
    static func fileURLs(inWebCustomData data: Data, fileExists: (String) -> Bool) -> [URL] {
        let map = decode(data)
        guard let list = uriListKeys.lazy.compactMap({ map[$0] }).first else { return [] }
        var seen = Set<String>()
        var urls: [URL] = []
        // The uri-list grammar is CRLF-separated with `#` comment lines. LF
        // alone is tolerated because not every writer honours the spec.
        for line in list.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let url = URL(string: trimmed), url.scheme == "file", url.isFileURL
            else { continue }
            guard fileExists(url.path), seen.insert(url.path).inserted else { continue }
            urls.append(url)
        }
        return urls
    }
}

extension NSPasteboard {
    func fileURLs() -> [URL] {
        let native = (readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        // Only when AppKit found at most one file is Chromium's payload worth
        // reading, and only when it names more than AppKit did. Finder drags
        // never reach it, and a Chromium drag of a single file is already
        // right — so the recovered list has to *add* something to be used.
        if native.count <= 1,
           let custom = data(forType: .chromiumWebCustomData) {
            let recovered = ChromiumCustomData.fileURLs(inWebCustomData: custom) {
                FileManager.default.fileExists(atPath: $0)
            }
            if recovered.count > native.count { return recovered }
        }
        if !native.isEmpty { return native }
        if let raw = string(forType: .URL),
           let url = URL(string: raw), url.scheme == "file", url.isFileURL {
            return [url]
        }
        return []
    }
}

extension NSPasteboard.PasteboardType {
    static let chromiumWebCustomData =
        NSPasteboard.PasteboardType("org.chromium.web-custom-data")
}

extension URL {
    var isExistingDirectory: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }
}

enum PluginDispatch {
    nonisolated static func extensionToType(_ ext: String) -> PluginInputType {
        let lower = ext.lowercased()
        if pluginImageExtensions.contains(lower) { return .image }
        if lower == "pdf" { return .pdf }
        return .file
    }

    /// The image bytes to hand a plugin, and the extension that names them.
    /// An ordinary ⌘⇧⌃4 screenshot puts *both* PNG and TIFF on the pasteboard,
    /// so this is a preference, not a fallback chain: PNG wins because it is a
    /// third the size and Obsidian renders no TIFF at all, so a TIFF
    /// attachment embeds as a blank. The extension is derived from the data
    /// actually chosen — picking the bytes and the name from separate
    /// pasteboard queries once wrote TIFF into a `.png` file, which embeds
    /// broken *and* hides the reason.
    nonisolated static func imagePayload(
        png: Data?, tiff: Data?
    ) -> (data: Data, ext: String)? {
        if let png { return (png, "png") }
        if let tiff { return (tiff, "tiff") }
        return nil
    }

    @MainActor static func classify(
        _ pasteboard: NSPasteboard
    ) -> (PluginInputType, PluginRunner.Input)? {
        let sourceApp = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier

        let fileURLs = pasteboard.fileURLs()
        if !fileURLs.isEmpty {
            if let dir = fileURLs.first(where: { $0.isExistingDirectory }) {
                DebugLog.log("plugin dispatch: classified as folder, path=\(dir.path)")
                return (.folder, PluginRunner.Input(
                    type: .folder,
                    text: nil,
                    filePath: dir.path,
                    sourceApp: sourceApp
                ))
            }
            let nonMD = fileURLs.filter {
                $0.pathExtension.lowercased() != "md"
            }
            if let first = nonMD.first {
                let type = extensionToType(first.pathExtension)
                DebugLog.log("plugin dispatch: classified as \(type.rawValue), file=\(first.path)")
                return (type, PluginRunner.Input(
                    type: type,
                    text: nil,
                    filePath: first.path,
                    sourceApp: sourceApp
                ))
            }
        }

        // URL string.
        if let urlString = pasteboard.string(forType: .URL)
            ?? pasteboard.string(forType: .string),
            let url = URL(string: urlString),
            url.scheme == "http" || url.scheme == "https" {
            // Length only, never content: clipboards carry passwords, and the
            // debug log is a file on disk.
            DebugLog.log("plugin dispatch: classified as url (\(urlString.count) chars)")
            return (.url, PluginRunner.Input(
                type: .url,
                text: urlString,
                filePath: nil,
                sourceApp: sourceApp
            ))
        }

        // Image data (PNG preferred, TIFF accepted) → write to temp file.
        if let payload = imagePayload(
            png: pasteboard.data(forType: .png),
            tiff: pasteboard.data(forType: .tiff)
        ) {
            let tempDir = NSTemporaryDirectory() + "chestnut-plugins"
            try? FileManager.default.createDirectory(
                atPath: tempDir, withIntermediateDirectories: true
            )
            let tempFile = tempDir + "/paste-\(UUID().uuidString).\(payload.ext)"
            if FileManager.default.createFile(
                atPath: tempFile, contents: payload.data
            ) {
                DebugLog.log("plugin dispatch: classified as image, temp=\(tempFile)")
                return (.image, PluginRunner.Input(
                    type: .image,
                    text: nil,
                    filePath: tempFile,
                    sourceApp: sourceApp
                ))
            }
        }

        // Plain string.
        if let text = pasteboard.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DebugLog.log("plugin dispatch: classified as text (\(text.count) chars)")
            return (.text, PluginRunner.Input(
                type: .text,
                text: text,
                filePath: nil,
                sourceApp: sourceApp
            ))
        }

        DebugLog.log("plugin dispatch: nothing classifiable on pasteboard")
        return nil
    }

    @MainActor static func classifyDrag(
        _ sender: NSDraggingInfo
    ) -> (PluginInputType, PluginRunner.Input)? {
        let pb = sender.draggingPasteboard
        let urls = pb.fileURLs()
        if !urls.isEmpty {
            let allMD = urls.allSatisfy {
                $0.pathExtension.lowercased() == "md"
            }
            if allMD { return nil }
        }
        return classify(pb)
    }
}
