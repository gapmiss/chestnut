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
}
