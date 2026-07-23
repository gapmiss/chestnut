import Foundation

enum PluginError: LocalizedError {
    case timeout
    case nonZeroExit(String)
    case badStructuredOutput(truncated: Bool)
    case scriptNotFound

    var errorDescription: String? {
        switch self {
        case .timeout: "Plugin timed out."
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
        env["CHESTNUT_TIMESTAMP"] = iso8601.string(from: Date())
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

    static func run(
        manifest: PluginManifest, pluginDir: URL, input: Input
    ) async throws -> RawResult {
        let scriptURL = manifest.scriptURL
        let timeout = manifest.timeout
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
            let maxBytes = 1_048_576
            let stdoutBuf = PipeBuffer(limit: maxBytes)
            let stderrBuf = PipeBuffer(limit: maxBytes)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stdoutBuf.append(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrBuf.append(chunk)
                }
            }

            let timedOut = OnceFlag()

            process.terminationHandler = { proc in
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + 0.1
                ) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutBuf.append(
                        stdoutPipe.fileHandleForReading.availableData)
                    stderrBuf.append(
                        stderrPipe.fileHandleForReading.availableData)

                    if once.tryFire() {
                        if timedOut.hasFired {
                            continuation.resume(throwing: PluginError.timeout)
                        } else {
                            continuation.resume(returning: RawResult(
                                exitCode: proc.terminationStatus,
                                stdout: stdoutBuf.string,
                                stderr: stderrBuf.string,
                                stdoutTruncated: stdoutBuf.truncated
                            ))
                        }
                    }
                }
            }

            do {
                try process.run()
                setpgid(process.processIdentifier, process.processIdentifier)
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
                DispatchQueue.global().async {
                    handle.write(data)
                    handle.closeFile()
                }
            }

            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout
            ) {
                guard process.isRunning else { return }
                let pid = process.processIdentifier
                _ = timedOut.tryFire()
                kill(-pid, SIGTERM)
                process.terminate()

                DispatchQueue.global().asyncAfter(
                    deadline: .now() + 1
                ) {
                    if process.isRunning {
                        kill(-pid, SIGKILL)
                    }
                }
            }
        }
    }

    static func interpret(
        result: RawResult, manifest: PluginManifest
    ) throws -> InterpretedResult {
        guard result.exitCode == 0 else {
            let msg = result.stderr.split(separator: "\n").first
                .map(String.init) ?? "exit code \(result.exitCode)"
            throw PluginError.nonZeroExit(msg)
        }

        if manifest.output == .structured {
            guard let data = result.stdout.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(
                      PluginEnvelope.self, from: data
                  ),
                  let action = PluginOutputMode(rawValue: envelope.action),
                  action != .structured
            else {
                throw PluginError.badStructuredOutput(truncated: result.stdoutTruncated)
            }
            return InterpretedResult(
                action: action,
                content: envelope.content ?? "",
                filename: envelope.filename,
                vaultHint: envelope.vault,
                folder: envelope.folder,
                notifyText: envelope.notify,
                attachments: envelope.attachments
            )
        }

        var content = result.stdout
        var filename: String? = nil

        if manifest.output == .save {
            let lines = content.split(
                separator: "\n", maxSplits: 1, omittingEmptySubsequences: false
            )
            if let first = lines.first {
                var name = String(first)
                for c: Character in ["/", "\\", ":"] {
                    name = name.replacingOccurrences(of: String(c), with: "-")
                }
                name = String(name.prefix(200))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    if !name.hasSuffix(".md") { name += ".md" }
                    filename = name
                }
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
