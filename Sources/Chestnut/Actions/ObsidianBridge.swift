import AppKit

/// Hands actions off to Obsidian. Always path-based (`obsidian://open?path=…`)
/// so duplicate vault names stay unambiguous; Obsidian focuses the vault if
/// it's open and launches it if not.
///
/// Obsidian 1.13's URL handler can silently fail to raise the window of an
/// already-open vault (long-lived windows stop responding to the focus step;
/// freshly opened ones are fine — reproduced with a bare `open` in Terminal,
/// 2026-07-15). When the CLI is present, `openVault` verifies the switch
/// landed and, if not, raises the matching window itself. Without the CLI
/// the URL open behaves exactly as before (hard invariant: CLI is an
/// optional enhancement).
@MainActor
enum ObsidianBridge {
    static func openVault(path: String) {
        guard let url = openURL(path: path) else {
            NSLog("ObsidianBridge: could not build URL for %@", path)
            return
        }
        NSWorkspace.shared.open(url)
        raiseIfFocusFailed(vaultPath: path)
    }

    /// Open a specific note (absolute path). The focus fallback is keyed to
    /// the containing vault's path — that's what the CLI reports as active.
    static func openNote(path: String, vaultPath: String) {
        guard let url = openURL(path: path) else {
            NSLog("ObsidianBridge: could not build URL for %@", path)
            return
        }
        NSWorkspace.shared.open(url)
        raiseIfFocusFailed(vaultPath: vaultPath)
    }

    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Present a delivered file or folder inside Obsidian. The vault opens
    /// via URL as always; when the CLI is present, a follow-up opens
    /// displayable files in a tab and reveals everything else (folders
    /// included) in Obsidian's file explorer — `obsidian://open` can't do
    /// either for non-markdown files. The follow-up waits out a cold app
    /// launch, and every failure leaves the plain vault open untouched.
    static func presentFile(path: String, vaultPath: String) {
        let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else {
            openVault(path: vaultPath)  // nothing presentable — plain vault open
            return
        }
        guard let url = openURL(path: vaultPath) else {
            NSLog("ObsidianBridge: could not build URL for %@", vaultPath)
            return
        }
        NSWorkspace.shared.open(url)
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let openInTab = !isDirectory.boolValue
            && displayableExtensions.contains((path as NSString).pathExtension.lowercased())
        let relative = String(path.dropFirst(prefix.count))
        presentWhenReady(
            script: presentScript(vaultPath: vaultPath, relativePath: relative, open: openInTab),
            vaultPath: vaultPath
        )
    }

    /// Exposed for verification; `path` may point at a vault or a note in it.
    static func openURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    // MARK: - Focus fallback (CLI, optional)

    /// Poll the CLI for the active vault while the URL open acts; a working
    /// switch lands within a poll or two and costs nothing extra. After two
    /// consecutive mismatches (~600ms) raise the target vault's window
    /// directly — the raise is idempotent, so losing a race against a slow
    /// but working switch is harmless. Every exit is silent-safe: no CLI, a
    /// CLI error, or a still-launching vault just leaves the URL open's
    /// behavior untouched.
    private static func raiseIfFocusFailed(vaultPath: String) {
        Task.detached {
            guard ObsidianCLI.url != nil else { return }
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let active = runCLI(["vault", "info=path"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                else { return }
                if active == vaultPath { return }
            }
            let result = runCLI(["eval", "code=\(focusScript(vaultPath: vaultPath))"], timeout: 5)
            NSLog("ObsidianBridge: focus fallback for %@ -> %@", vaultPath, result ?? "CLI error")
        }
    }

    /// JavaScript run inside Obsidian (CLI `eval`) to raise the window whose
    /// vault matches `vaultPath` — matched by path, never by name, since the
    /// registry proves names collide. Exposed for verification.
    nonisolated static func focusScript(vaultPath: String) -> String {
        guard let quoted = jsonQuoted(vaultPath) else { return "" }
        return windowScript(vaultQuoted: quoted, body: "return \"focused\";")
    }

    // MARK: - Attachment presentation (CLI, optional)

    /// File types Obsidian can display in a tab. Anything else only gets a
    /// file-explorer reveal — in-app it would bounce to the default app anyway.
    nonisolated private static let displayableExtensions: Set<String> = [
        "md", "canvas", "base", "pdf",
        "png", "jpg", "jpeg", "gif", "bmp", "svg", "webp", "avif",
        "mp3", "wav", "m4a", "ogg", "3gp", "flac",
        "mp4", "webm", "ogv", "mov", "mkv",
    ]

    /// JavaScript run inside Obsidian to focus the window whose vault matches
    /// `vaultPath` and, inside it, open `relativePath` in a tab (`open`) or
    /// reveal it in the file explorer (`revealInFolder` is the same internal
    /// API community "reveal file" plugins use; it takes files and folders).
    /// Distinct "no-…" returns let the caller retry while Obsidian is still
    /// launching or indexing. Exposed for verification.
    nonisolated static func presentScript(
        vaultPath: String, relativePath: String, open: Bool
    ) -> String {
        let inner: String
        guard let relQuoted = jsonQuoted(relativePath) else { return "" }
        if open {
            inner = "(async () => { const f = app.vault.getAbstractFileByPath(\(relQuoted)); "
                + "if (!f) return \"no-file\"; "
                + "await app.workspace.getLeaf(false).openFile(f); return \"opened\"; })()"
        } else {
            inner = "(async () => { "
                + "const fe = app.internalPlugins.getEnabledPluginById(\"file-explorer\"); "
                + "if (!fe) return \"no-explorer\"; "
                + "const f = app.vault.getAbstractFileByPath(\(relQuoted)); "
                + "if (!f) return \"no-file\"; "
                + "app.workspace.leftSplit.expand(); fe.revealInFolder(f); "
                + "return \"revealed\"; })()"
        }
        guard let vaultQuoted = jsonQuoted(vaultPath),
              let innerQuoted = jsonQuoted(inner)
        else { return "" }
        return windowScript(
            vaultQuoted: vaultQuoted,
            body: "return await win.webContents.executeJavaScript(\(innerQuoted));"
        )
    }

    /// Retry the present script until the vault's window is up and the file
    /// is indexed — a cold Obsidian launch takes several seconds, during
    /// which the CLI errors ("no CLI reply") or the script finds no window.
    /// Deadline-bounded and silent-safe: expiry just leaves the URL-opened
    /// vault as-is.
    private static func presentWhenReady(script: String, vaultPath: String) {
        Task.detached {
            guard !script.isEmpty, ObsidianCLI.url != nil else { return }
            let deadline = Date().addingTimeInterval(12)
            var result: String?
            repeat {
                try? await Task.sleep(for: .milliseconds(400))
                result = runCLI(["eval", "code=\(script)"], timeout: 5)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let result, !result.contains("no-") { break }
            } while Date() < deadline
            NSLog("ObsidianBridge: present in %@ -> %@", vaultPath, result ?? "no CLI reply")
        }
    }

    /// Shared outer loop for `eval` scripts: iterate Obsidian's windows,
    /// match by vault basePath, focus the match, run `body` with `win` in
    /// scope. JSON-encoding every interpolated value keeps quotes and
    /// backslashes from breaking out; the CLI takes the code as a single
    /// key=value argument, so the script must stay on one line.
    nonisolated private static func windowScript(vaultQuoted: String, body: String) -> String {
        "(async () => { const remote = require(\"@electron/remote\"); "
            + "for (const win of remote.BrowserWindow.getAllWindows()) { try { "
            + "const path = await win.webContents.executeJavaScript("
            + "\"window.app && window.app.vault ? window.app.vault.adapter.basePath : null\"); "
            + "if (path === \(vaultQuoted)) { win.show(); win.focus(); \(body) } "
            + "} catch (e) {} } return \"no-window\"; })()"
    }

    nonisolated private static func jsonQuoted(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(
                  withJSONObject: value, options: .fragmentsAllowed)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Run the CLI with a hard timeout (it talks to the live app and can
    /// hang without it). Returns stdout on success; nil on failure, timeout,
    /// or an "Error:" reply. Mirrors `Capture.runCLI`.
    nonisolated private static func runCLI(
        _ arguments: [String], timeout: TimeInterval = 3
    ) -> String? {
        guard let cli = ObsidianCLI.url else { return nil }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              !output.hasPrefix("Error")
        else { return nil }
        return output
    }
}
