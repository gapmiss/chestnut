import Foundation

/// Locates the optional `obsidian` CLI (see spec §9). Hard invariant: the CLI
/// is an enhancement only — every caller has a direct-FS fallback.
///
/// Candidates are a fixed list of trusted install locations, never a $PATH
/// search (a writable PATH entry must not decide what Chestnut executes):
/// Homebrew installs to /opt/homebrew/bin on Apple Silicon and /usr/local/bin
/// on Intel.
enum ObsidianCLI {
    static let candidatePaths = [
        "/opt/homebrew/bin/obsidian",
        "/usr/local/bin/obsidian",
    ]

    /// The first executable candidate, or nil when the CLI is not installed.
    static var url: URL? {
        candidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Run the CLI with a hard timeout (it talks to the live app and can
    /// hang without it). Returns stdout on success; nil on failure, timeout,
    /// or an "Error:" reply.
    nonisolated static func run(
        _ arguments: [String], timeout: TimeInterval = 3
    ) -> String? {
        guard let cli = url else { return nil }
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
