import AppKit
import Foundation

private let pluginImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff",
    "tif", "svg",
]

enum PluginDispatch {
    nonisolated static func extensionToType(_ ext: String) -> PluginInputType {
        let lower = ext.lowercased()
        if pluginImageExtensions.contains(lower) { return .image }
        if lower == "pdf" { return .pdf }
        return .file
    }

    @MainActor static func classify(
        _ pasteboard: NSPasteboard
    ) -> (PluginInputType, PluginRunner.Input)? {
        let sourceApp = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier

        // File URLs (skip if all .md).
        var fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        // Electron apps put file:// URLs on public.url instead of
        // public.file-url — urlReadingFileURLsOnly skips them.
        if fileURLs.isEmpty,
           let raw = pasteboard.string(forType: .URL),
           let url = URL(string: raw), url.scheme == "file", url.isFileURL {
            fileURLs = [url]
        }
        if !fileURLs.isEmpty {
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
            DebugLog.log("plugin dispatch: classified as url (\(urlString.prefix(80)))")
            return (.url, PluginRunner.Input(
                type: .url,
                text: urlString,
                filePath: nil,
                sourceApp: sourceApp
            ))
        }

        // Image data (TIFF/PNG) → write to temp file.
        if let imageData = pasteboard.data(forType: .tiff)
            ?? pasteboard.data(forType: .png) {
            let tempDir = NSTemporaryDirectory() + "chestnut-plugins"
            try? FileManager.default.createDirectory(
                atPath: tempDir, withIntermediateDirectories: true
            )
            let ext = pasteboard.data(forType: .png) != nil ? "png" : "tiff"
            let tempFile = tempDir + "/paste-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970)).\(ext)"
            if FileManager.default.createFile(
                atPath: tempFile, contents: imageData
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
            DebugLog.log("plugin dispatch: classified as text (\(text.prefix(80)))")
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
        // Guard: if all dragged items are .md file URLs, return nil so
        // the caller falls through to the courier.
        var urls = (pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        if urls.isEmpty,
           let raw = pb.string(forType: .URL),
           let url = URL(string: raw), url.scheme == "file", url.isFileURL {
            urls = [url]
        }
        if !urls.isEmpty {
            let allMD = urls.allSatisfy {
                $0.pathExtension.lowercased() == "md"
            }
            if allMD { return nil }
        }
        return classify(pb)
    }
}
