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

    /// Cap on buffered stdout. Every reply the app asks for is a vault path or
    /// a one-word status, so a megabyte is far past "this went wrong"; past the
    /// cap the reply is discarded and the call reports failure, which drops the
    /// caller onto its direct-FS fallback rather than handing it a half string.
    static let maxOutputBytes = 1_048_576

    /// How long to wait for end-of-stream *after* the process exits. EOF only
    /// arrives once every writer closes the pipe, so a helper the CLI
    /// backgrounded — which inherits the write end — can keep it from ever
    /// arriving. The readability handlers have already captured everything
    /// written; this is purely the "no more is coming" signal, and when it
    /// never comes we answer with what was buffered. Same bound, and the same
    /// reason, as `PluginRunner`'s grace period.
    private static let drainGrace: TimeInterval = 0.5

    /// Run the CLI with a hard timeout (it talks to the live app and can
    /// hang without it). Returns stdout on success; nil on failure, timeout,
    /// or an "Error:" reply.
    nonisolated static func run(
        _ arguments: [String], timeout: TimeInterval = 3
    ) -> String? {
        guard let cli = url else { return nil }
        return run(cli, arguments: arguments, timeout: timeout)
    }

    /// The executable is a parameter so `make check` can drive real
    /// subprocesses without the CLI installed — the same move `PetGeometry`
    /// makes with screens. Callers in the app go through `run(_:timeout:)`,
    /// which supplies a trusted-path binary; nothing here re-checks the path,
    /// so do not widen this to a caller that takes one from the user.
    nonisolated static func run(
        _ cli: URL, arguments: [String], timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes continuously. Read only after the process exits and
        // a reply past the pipe buffer (~64 KB on macOS) blocks the child in
        // `write()` — it can never exit, so the wait below burns its whole
        // timeout and returns nil. stderr is the same trap without the payoff:
        // it was set and never read at all, so a long trace wedged calls whose
        // actual reply was one line.
        let output = OutputBuffer(limit: maxOutputBytes)
        let eof = DispatchSemaphore(value: 0)  // signalled once per stream

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            } else {
                output.append(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            }
            // Nothing reads the CLI's stderr; it is drained to keep the child
            // from blocking on it, and dropped.
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Clearing the handlers releases our read sources on every exit,
        // including the timeout and the `run()` throw. Left installed against a
        // child that outlived us, they hold a GCD thread apiece.
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        do { try process.run() } catch { return nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }

        // One deadline shared by both waits, so the grace period is 0.5s total
        // rather than 0.5s per stream.
        let graceEnd = DispatchTime.now() + drainGrace
        _ = eof.wait(timeout: graceEnd)
        _ = eof.wait(timeout: graceEnd)

        guard process.terminationStatus == 0, !output.truncated else { return nil }
        guard let text = String(data: output.data, encoding: .utf8),
              !text.hasPrefix("Error")
        else { return nil }
        return text
    }
}

/// Accumulates a pipe's bytes under a lock, since the readability handler fires
/// on a GCD thread. Past `limit` it keeps *reading* and discards: draining is
/// the whole point, so stopping would reintroduce the deadlock the cap sits
/// beside. `truncated` is how the caller learns the reply is not a reply.
private final class OutputBuffer: @unchecked Sendable {
    private var bytes = Data()
    private var overflowed = false
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard bytes.count + chunk.count <= limit else {
            overflowed = true
            return
        }
        bytes.append(chunk)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }
}
