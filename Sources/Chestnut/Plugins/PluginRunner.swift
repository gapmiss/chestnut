import Foundation

enum PluginError: LocalizedError {
    case timeout
    /// Ended from the Running Plugins submenu. Distinct from `.timeout` because
    /// the notice would otherwise tell the user their plugin ran too long when
    /// what happened is that they stopped it.
    case cancelled
    case nonZeroExit(String)
    case badStructuredOutput(truncated: Bool)
    case scriptNotFound

    var errorDescription: String? {
        switch self {
        case .timeout: "Plugin timed out."
        case .cancelled: "Plugin cancelled."
        case .nonZeroExit(let msg): "Plugin failed: \(msg)"
        case .badStructuredOutput(true):
            "Plugin returned invalid structured output (stdout exceeded 1 MB and was truncated)."
        case .badStructuredOutput(false):
            "Plugin returned invalid structured output."
        case .scriptNotFound: "Plugin script not found or not executable."
        }
    }
}

enum PluginRunner {
    struct Input: Sendable {
        let type: PluginInputType
        let text: String?
        let filePath: String?
        let sourceApp: String?
    }

    struct RawResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var stdoutTruncated: Bool = false
        /// Streaming runs only. The last envelope that was *not* a `notify` —
        /// the one thing the run is asking Chestnut to do. `notify` envelopes
        /// have already been delivered live by the time this is read, and
        /// stdout is not accumulated at all on that path, so this is the whole
        /// of what a streamed run carries back.
        var streamedEnvelope: PluginEnvelope? = nil
        /// Streaming runs only: lines that were not valid JSON. Skipped, not
        /// fatal; kept as a count so the log can say how many.
        var skippedLines: Int = 0
    }

    struct InterpretedResult: Sendable {
        let action: PluginOutputMode
        let content: String
        let filename: String?
        let vaultHint: String?
        let folder: String?
        let notifyText: String?
        let attachments: [PluginAttachment]?
    }

    static func environment(
        for input: Input, pluginDir: URL
    ) -> [String: String] {
        var env: [String: String] = [:]
        env["CHESTNUT_INPUT_TYPE"] = input.type.rawValue
        env["CHESTNUT_SOURCE_APP"] = input.sourceApp ?? ""
        env["CHESTNUT_FILE_PATH"] = input.filePath ?? ""
        env["CHESTNUT_TIMESTAMP"] = iso8601Timestamp()
        env["CHESTNUT_PLUGIN_DIR"] = pluginDir.path
        let basePath = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin"
        let extras = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = basePath.contains("/opt/homebrew")
            ? basePath : "\(extras):\(basePath)"
        env["HOME"] = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return env
    }

    /// Longest single line a streaming plugin may print. Past this the line is
    /// cut and the remainder discarded up to the next newline; the stub will
    /// not decode as JSON, so it is skipped and counted like any other bad
    /// line. This is per line rather than per run on purpose — a total cap
    /// would let a four-hour run's thousandth progress message truncate away
    /// the `save` envelope it prints at the end.
    static let maxStreamLine = 65_536

    /// `handle` is the caller's way back into a run that has already started —
    /// it is what the run registry keeps and what the cancel row signals. A
    /// caller with nothing to cancel can leave it defaulted.
    ///
    /// `onNotify` receives streamed progress messages as they are printed, on a
    /// background thread and in order. It is called only for a plugin with
    /// `"stream": true`.
    static func run(
        manifest: PluginManifest, pluginDir: URL, input: Input,
        handle: PluginRunHandle = PluginRunHandle(),
        onNotify: (@Sendable (String) -> Void)? = nil
    ) async throws -> RawResult {
        let scriptURL = manifest.scriptURL
        let timeout = manifest.timeout
        let streaming = manifest.stream
        let env = environment(for: input, pluginDir: pluginDir)
        let stdinText = input.text
        let stdinType = input.type

        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()

            let process = Process()
            process.executableURL = scriptURL
            process.currentDirectoryURL = pluginDir
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdinPipe: Pipe?
            if stdinText != nil,
               (stdinType == .text || stdinType == .url) {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
            } else {
                process.standardInput = FileHandle.nullDevice
                stdinPipe = nil
            }

            // Drain pipes continuously so the process never blocks on a
            // full pipe buffer (~64 KB on macOS). Each readabilityHandler
            // fires on a GCD thread whenever data is available; EOF
            // (empty data) clears the handler.
            //
            // The 1 MB cap is on *total* stdout, and raising the timeout
            // ceiling to four hours put it within reach: a plugin that prints
            // steadily for an hour fills it, and in `structured` mode a
            // truncated envelope no longer parses, so the run fails with
            // `badStructuredOutput(truncated: true)`. That error blames the
            // plugin for a buffer its author never knew about, which is why the
            // limit is now stated outright in PLUGINS.md rather than left to be
            // discovered. A plugin with progress to report should set
            // `"stream": true` and emit one envelope per line — that path caps
            // each line instead of the total, so a long run cannot lose its
            // final envelope to something it printed an hour earlier.
            let maxBytes = 1_048_576
            let stdoutBuf = PipeBuffer(limit: maxBytes)
            let stderrBuf = PipeBuffer(limit: maxBytes)
            let drained = DrainGate(streams: 2)

            // Streaming reads stdout a line at a time and keeps nothing but the
            // last non-`notify` envelope, so a long run's memory does not grow
            // with what it prints and the 1 MB total cap never applies to it.
            let collector = StreamCollector()
            let lines = LineBuffer(lineLimit: maxStreamLine) { line in
                collector.consume(line, onNotify: onNotify)
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if streaming { lines.flush() }
                    drained.streamClosed()
                } else if streaming {
                    lines.append(chunk)
                } else {
                    stdoutBuf.append(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    drained.streamClosed()
                } else {
                    stderrBuf.append(chunk)
                }
            }

            // Resolve on EOF, never with a blocking tail read. EOF only
            // arrives once every writer closes the pipe, and a child the
            // script backgrounded (`helper &`) inherits the write end — a
            // blocking read here waited on that child forever, leaking the
            // continuation and leaving the pet chewing. The readability
            // handlers already capture everything written, so EOF is purely
            // the "no more is coming" signal; when a surviving child keeps it
            // from ever arriving, the grace period resumes with what's
            // buffered.
            process.terminationHandler = { proc in
                let status = proc.terminationStatus
                handle.finished()
                let finish: @Sendable () -> Void = {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    guard once.tryFire() else { return }
                    if let ending = handle.ending {
                        continuation.resume(throwing: ending.error)
                    } else {
                        continuation.resume(returning: RawResult(
                            exitCode: status,
                            stdout: streaming ? "" : stdoutBuf.string,
                            stderr: stderrBuf.string,
                            stdoutTruncated: stdoutBuf.truncated,
                            streamedEnvelope: collector.envelope,
                            skippedLines: collector.skippedLines
                        ))
                    }
                }
                drained.whenAllClosed(finish)
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + 0.5
                ) {
                    finish()
                }
            }

            do {
                try process.run()
                handle.launched(process)
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if once.tryFire() {
                    continuation.resume(throwing: PluginError.scriptNotFound)
                }
                return
            }

            if let pipe = stdinPipe, let text = stdinText {
                let data = Data(text.utf8)
                let handle = pipe.fileHandleForWriting
                // Close the parent's copy of the read end — the child has its
                // own dup. Left open, it props the pipe up after the child
                // exits, and a write past the ~64 KB buffer to a plugin that
                // never reads stdin would block until the Process object dies.
                try? pipe.fileHandleForReading.close()
                DispatchQueue.global().async {
                    // The write is best-effort: a plugin that exits without
                    // reading stdin (env-vars-only is a normal shape) makes it
                    // fail with EPIPE. NOSIGPIPE turns the signal — whose
                    // default action kills the whole app — into that error,
                    // and the throwing write surfaces it as a catchable throw
                    // where the legacy `write(_:)` raised an uncatchable ObjC
                    // exception.
                    _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            }

            // The timeout is one of two ways a run is ended from outside; the
            // cancel row is the other. Both go through `PluginRunHandle.end`,
            // which owns the group-signalling and the escalation to SIGKILL —
            // read its doc comment before changing how a plugin is killed. This
            // path fires only when the script is still running: one that exits
            // cleanly leaves its background children alive, which the
            // termination handler above tolerates on purpose.
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout
            ) {
                handle.end(.timedOut)
            }
        }
    }

    /// What a run is asking Chestnut to do, or nil when it is asking for
    /// nothing. Nil happens only on a streaming run that printed progress and
    /// then stopped: it has already said everything it had to say, and a
    /// closing notice repeating the last progress line would be noise.
    ///
    /// **A plugin that fails writes nothing, and streaming did not change
    /// that.** The exit code is checked first, before any envelope is acted on,
    /// which is what lets an author print an envelope and then abort. Under
    /// streaming this is why only `notify` is delivered live (see
    /// `StreamCollector`): everything that writes a file, replaces the
    /// clipboard or opens a panel is held here until the exit code says the run
    /// succeeded. Loosening that would mean a plugin exiting 1 could still have
    /// left three notes in a vault, with the exit code arriving too late to
    /// gate them.
    /// Log from `interpret`, which is `nonisolated` while `DebugLog` is
    /// `@MainActor`. The hop is deferred rather than awaited so `interpret`
    /// keeps its synchronous signature: making it `@MainActor` instead would
    /// compile here but not in `Checks/main.swift` or the hand-test probe,
    /// both of which call it off the main actor. The cost is that these lines
    /// can land in the log a moment after the ones the caller writes.
    private static func logLater(_ message: String) {
        Task { @MainActor in DebugLog.log(message) }
    }

    static func interpret(
        result: RawResult, manifest: PluginManifest
    ) throws -> InterpretedResult? {
        guard result.exitCode == 0 else {
            let msg = result.stderr.split(separator: "\n").first
                .map(String.init) ?? "exit code \(result.exitCode)"
            throw PluginError.nonZeroExit(msg)
        }

        if manifest.stream {
            guard let envelope = result.streamedEnvelope else { return nil }
            guard let interpreted = interpretEnvelope(envelope) else {
                logLater(
                    "plugin \(manifest.name): streamed envelope decoded but "
                        + "describes no action this build can carry out "
                        + "(action=\(envelope.action))")
                throw PluginError.badStructuredOutput(truncated: false)
            }
            return interpreted
        }

        if manifest.output == .structured {
            // The notice can only ever say "invalid structured output" — it has
            // no room for a parser message and the person reading it may not be
            // the person who wrote the plugin. So the reason goes to the debug
            // log, which is where a plugin author already looks. Three distinct
            // failures hide behind one error case, and telling them apart is
            // most of the debugging: stdout that is not UTF-8, JSON the decoder
            // rejects (a raw newline inside a string value is the one that
            // catches everybody), and a valid envelope naming an action this
            // build does not implement.
            guard let data = result.stdout.data(using: .utf8) else {
                logLater(
                    "plugin \(manifest.name): stdout is not valid UTF-8")
                throw PluginError.badStructuredOutput(truncated: result.stdoutTruncated)
            }
            let envelope: PluginEnvelope
            do {
                envelope = try JSONDecoder().decode(PluginEnvelope.self, from: data)
            } catch {
                logLater(
                    "plugin \(manifest.name): stdout is not valid JSON — \(error)"
                        + (result.stdoutTruncated ? " (stdout was truncated at 1 MB)" : "")
                        + "\n  stdout began: \(result.stdout.prefix(200))")
                throw PluginError.badStructuredOutput(truncated: result.stdoutTruncated)
            }
            guard let interpreted = interpretEnvelope(envelope) else {
                logLater(
                    "plugin \(manifest.name): envelope decoded but describes no "
                        + "action this build can carry out (action=\(envelope.action))")
                throw PluginError.badStructuredOutput(truncated: result.stdoutTruncated)
            }
            return interpreted
        }

        var content = result.stdout
        var filename: String? = nil

        if manifest.output == .save {
            let lines = content.split(
                separator: "\n", maxSplits: 1, omittingEmptySubsequences: false
            )
            if let first = lines.first {
                filename = sanitizedFilename(String(first), requireMarkdown: true)
                content = lines.count > 1 ? String(lines[1]) : ""
            }
        }

        return InterpretedResult(
            action: manifest.output,
            content: content,
            filename: filename,
            vaultHint: nil,
            folder: nil,
            notifyText: nil,
            attachments: nil
        )
    }

    /// One envelope, turned into one thing to do. Both routes into structured
    /// output call this — the whole of stdout decoded at exit, and a single
    /// streamed line — so they cannot disagree about what an envelope means.
    /// Same argument as `sanitizedFilename`: one grammar, one place.
    ///
    /// Returns nil for an action Chestnut does not have, and for `structured`
    /// itself, which would ask the runner to interpret its own output again.
    static func interpretEnvelope(_ envelope: PluginEnvelope) -> InterpretedResult? {
        guard let action = PluginOutputMode(rawValue: envelope.action),
              action != .structured
        else { return nil }
        return InterpretedResult(
            action: action,
            content: envelope.content ?? "",
            filename: envelope.filename.flatMap {
                sanitizedFilename($0, requireMarkdown: true)
            },
            vaultHint: envelope.vault,
            folder: envelope.folder,
            notifyText: envelope.notify,
            attachments: envelope.attachments.map { list in
                list.map {
                    PluginAttachment(
                        source: $0.source,
                        // No .md forced: an attachment is whatever it is.
                        filename: sanitizedFilename($0.filename, requireMarkdown: false)
                            ?? "attachment"
                    )
                }
            }
        )
    }

    /// What one line of a streaming plugin's stdout turned out to be.
    enum StreamedLine {
        /// A `notify` envelope, delivered to the user as it arrives.
        case progress(String)
        /// Anything else the run is asking for. Held until the run exits 0.
        case terminal(PluginEnvelope)
        /// Blank, or not valid JSON. Skipped and counted, never fatal — forty
        /// minutes of work must not be thrown away over one malformed
        /// progress line.
        case skipped
    }

    static func classifyStreamLine(_ line: String) -> StreamedLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                  PluginEnvelope.self, from: data
              )
        else { return .skipped }
        if envelope.action == PluginOutputMode.notify.rawValue {
            return .progress(envelope.notify ?? envelope.content ?? "")
        }
        return .terminal(envelope)
    }

    /// One grammar for every filename a plugin supplies, so plain `save` mode
    /// and the structured envelope can't disagree — the way `HotkeySpec` is
    /// one grammar for hotkeys. The structured path used to apply none of
    /// this, which produced two failures that named nothing useful:
    /// `"notes/today.md"` addressed a directory the save never creates, so the
    /// write failed with a bare "doesn't exist", and `"today"` wrote an
    /// extension-less file Obsidian won't display while reporting success.
    ///
    /// Separators become `-` rather than an error because subfolders already
    /// have a field: the envelope's `folder`, which *is* created (with
    /// intermediates) and containment-checked. Nothing is expressible only
    /// through a separator here. Returns nil when nothing usable is left.
    static func sanitizedFilename(_ raw: String, requireMarkdown: Bool) -> String? {
        var name = raw
        for c: Character in ["/", "\\", ":"] {
            name = name.replacingOccurrences(of: String(c), with: "-")
        }
        // Cap before trimming, matching the order plain `save` has always
        // used: a 200-character prefix can end mid-whitespace.
        name = String(name.prefix(200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if requireMarkdown, !name.hasSuffix(".md") { name += ".md" }
        return name
    }
}

/// The live process behind one plugin run, shared between `PluginRunner.run`
/// and `PluginRunRegistry` so a menu row can stop a process the runner owns.
///
/// Both ways a run can be ended from outside — the timeout and the cancel row —
/// go through `end`, so they cannot disagree about how a plugin dies or about
/// which error the run reports.
final class PluginRunHandle: @unchecked Sendable {
    enum Ending: Sendable {
        case timedOut
        case cancelled

        var error: PluginError {
            switch self {
            case .timedOut: .timeout
            case .cancelled: .cancelled
            }
        }
    }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var process: Process?
    private var _ending: Ending?

    /// Why the run was ended from outside, or nil if it ended on its own.
    var ending: Ending? {
        lock.lock()
        defer { lock.unlock() }
        return _ending
    }

    fileprivate func launched(_ process: Process) {
        lock.lock()
        self.process = process
        pid = process.processIdentifier
        lock.unlock()
    }

    /// Called from the termination handler. Dropping the `Process` here is what
    /// makes a later `end` a no-op rather than a signal aimed at a PID the
    /// kernel has already handed to somebody else.
    fileprivate func finished() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    /// Signals the whole process group (`kill(-pid, …)`), not just the script,
    /// so a plugin that backgrounded something goes down with it. Nothing here
    /// has to create that group: `Process` already spawns the child as its own
    /// group leader, so pgid == pid. Calling `setpgid` ourselves would not work
    /// anyway — by the time `run()` returns the child has exec'd, and POSIX
    /// rejects the call with EACCES from then on (measured: 5/5 failures, and
    /// the grandchild reaped 5/5 regardless).
    ///
    /// `SIGTERM` first so a script can clean up, `SIGKILL` a second later if the
    /// group is still there. Returns whether a signal was actually sent.
    ///
    /// **Why the ownership check, and why `isRunning` alone is not enough.**
    /// Signalling a *group* by number is a much bigger mistake than signalling
    /// one process: if the PID has been recycled, every process in a stranger's
    /// group gets the signal. It is tempting to assume the PID stays reserved
    /// while we hold the `Process` object, and that assumption is wrong —
    /// measured 3/3 on macOS 14: inside `terminationHandler`, `kill(pid, 0)`
    /// already fails with `ESRCH` and `waitpid` already fails with `ECHILD`.
    /// Foundation reaps the child before it tells us, so the PID is free for
    /// reuse from that moment, object or no object.
    ///
    /// `guard process.isRunning` is check-then-act and narrows the window
    /// without closing it. So the last thing before the signal is a question
    /// about the PID as it exists right now: `proc_pidinfo` is asked who its
    /// parent is, and the signal is sent only if the answer is us. A recycled
    /// PID belonging to another program has a different parent, and one
    /// belonging to another user's process fails the lookup outright (EPERM),
    /// so the check fails closed. What it cannot distinguish is a PID recycled
    /// onto *another plugin of ours*, which would need ~99,000 process
    /// launches (kern.pidmax) inside a window of microseconds; the damage there
    /// is bounded to cancelling the wrong plugin rather than to an unrelated
    /// process group.
    @discardableResult
    func end(_ ending: Ending) -> Bool {
        lock.lock()
        guard _ending == nil, let process, process.isRunning else {
            lock.unlock()
            return false
        }
        _ending = ending
        let pid = self.pid
        lock.unlock()

        guard PluginRunHandle.isOurChild(pid) else { return false }
        kill(-pid, SIGTERM)
        process.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            guard process.isRunning, PluginRunHandle.isOurChild(pid) else { return }
            kill(-pid, SIGKILL)
        }
        return true
    }

    /// Whether `pid` is, at this instant, a direct child of this process.
    /// Returns false when the PID does not exist, belongs to someone else, or
    /// cannot be inspected — every failure mode means "do not signal".
    static func isOurChild(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return false }
        return pid_t(info.pbi_ppid) == getpid()
    }
}

/// Splits a streaming plugin's stdout into lines as the bytes arrive, and
/// decides what each line was.
///
/// **Only `notify` is delivered live.** Everything else is held for
/// `PluginRunner.interpret` to apply after a clean exit, which is what keeps
/// the guarantee a plugin author already relies on: a plugin that fails writes
/// nothing. Acting on a `save` the moment it is printed would mean a plugin
/// emitting three saves and then exiting 1 has already put three notes in a
/// vault, with the exit code arriving too late to stop any of them — and three
/// separate journal records to click through to take them back.
///
/// It also settles the focus-stealing question by construction: `capture` opens
/// a panel, and a panel cannot be opened mid-run if nothing but `notify` is
/// acted on mid-run. What arrives at the *end* of a long run is handled
/// separately — see `AppDelegate.handlePluginResult`, which parks a late
/// capture behind a notice instead of grabbing focus.
///
/// The last terminal envelope wins, so a plugin that prints two `save`
/// envelopes performs one save. That is a plugin bug, and the alternative —
/// applying every one of them — is the multi-record undo problem this design
/// exists to avoid.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _envelope: PluginEnvelope?
    private var _skipped = 0

    var envelope: PluginEnvelope? {
        lock.lock(); defer { lock.unlock() }
        return _envelope
    }

    var skippedLines: Int {
        lock.lock(); defer { lock.unlock() }
        return _skipped
    }

    func consume(_ line: String, onNotify: (@Sendable (String) -> Void)?) {
        switch PluginRunner.classifyStreamLine(line) {
        case .progress(let text):
            onNotify?(text)
        case .terminal(let envelope):
            lock.lock()
            _envelope = envelope
            lock.unlock()
        case .skipped:
            lock.lock()
            _skipped += 1
            lock.unlock()
        }
    }
}

/// Turns the chunks a `readabilityHandler` delivers into whole lines. Chunk
/// boundaries have nothing to do with line boundaries, so a JSON envelope
/// routinely arrives split across two reads.
///
/// A line longer than `lineLimit` is cut there and the rest of it discarded up
/// to the next newline. The stub that survives will not decode, so it is
/// skipped and counted like any other bad line — a plugin that prints a
/// megabyte on one line loses that line, not the run.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    /// True while discarding the tail of a line that ran past the limit.
    private var overrun = false
    private let lineLimit: Int
    private let onLine: @Sendable (String) -> Void

    init(lineLimit: Int, onLine: @escaping @Sendable (String) -> Void) {
        self.lineLimit = lineLimit
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        // Lines are emitted outside the lock: `onLine` runs the collector and
        // the caller's notify callback, and holding a lock across either is
        // how a deadlock gets built.
        var ready: [String] = []
        lock.lock()
        let parts = chunk.split(
            separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false
        )
        for (index, part) in parts.enumerated() {
            if !overrun {
                let room = lineLimit - pending.count
                pending.append(contentsOf: part.prefix(room))
                if part.count >= room { overrun = true }
            }
            // Every part but the last was followed by a newline in this chunk;
            // the last is a line still in progress, waiting for the next read.
            guard index < parts.count - 1 else { continue }
            ready.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: true)
            overrun = false
        }
        lock.unlock()
        for line in ready { onLine(line) }
    }

    /// Whatever is left when the pipe closes. A plugin that prints its last
    /// envelope without a trailing newline is common enough that dropping it
    /// would look like Chestnut losing the result.
    func flush() {
        lock.lock()
        let tail = pending
        pending.removeAll()
        overrun = false
        lock.unlock()
        guard !tail.isEmpty else { return }
        onLine(String(decoding: tail, as: UTF8.self))
    }
}

/// Coordinates the termination handler with pipe EOF: both readability
/// handlers report EOF here, and the termination handler asks to run once
/// both have — immediately, if they already did. Waiting on this alone would
/// re-create the hang it replaces (a surviving child can hold a write end
/// open forever), so the caller pairs it with a bounded grace period.
private final class DrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var action: (@Sendable () -> Void)?

    init(streams: Int) { remaining = streams }

    func streamClosed() {
        lock.lock()
        remaining -= 1
        let fire = remaining == 0 ? action : nil
        if fire != nil { action = nil }
        lock.unlock()
        fire?()
    }

    func whenAllClosed(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        if remaining == 0 {
            lock.unlock()
            block()
        } else {
            action = block
            lock.unlock()
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

private final class PipeBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let limit: Int
    private var _truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        let room = limit - data.count
        if room > 0 {
            data.append(chunk.prefix(room))
            if chunk.count > room { _truncated = true }
        } else {
            _truncated = true
        }
        lock.unlock()
    }

    var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _truncated
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
