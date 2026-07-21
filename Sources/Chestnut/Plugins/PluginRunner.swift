import Foundation

enum PluginError: LocalizedError {
    case timeout
    case nonZeroExit(String)
    case badStructuredOutput
    case scriptNotFound

    var errorDescription: String? {
        switch self {
        case .timeout: "Plugin timed out."
        case .nonZeroExit(let msg): "Plugin failed: \(msg)"
        case .badStructuredOutput: "Plugin returned invalid structured output."
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
        env["CHESTNUT_TIMESTAMP"] = ISO8601DateFormatter().string(from: Date())
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

            if let text = stdinText,
               (stdinType == .text || stdinType == .url) {
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                stdinPipe.fileHandleForWriting.write(Data(text.utf8))
                stdinPipe.fileHandleForWriting.closeFile()
            } else {
                process.standardInput = FileHandle.nullDevice
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

            process.terminationHandler = { proc in
                // Handlers may still fire after termination; give GCD a
                // moment to deliver the final chunks then read anything
                // left in the pipe.
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
                        continuation.resume(returning: RawResult(
                            exitCode: proc.terminationStatus,
                            stdout: stdoutBuf.string,
                            stderr: stderrBuf.string
                        ))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if once.tryFire() {
                    continuation.resume(throwing: PluginError.scriptNotFound)
                }
                return
            }

            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout
            ) {
                if process.isRunning { process.terminate() }
                if once.tryFire() {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: PluginError.timeout)
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
                  let action = PluginOutputMode(rawValue: envelope.action)
            else {
                throw PluginError.badStructuredOutput
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

        return InterpretedResult(
            action: manifest.output,
            content: result.stdout,
            filename: nil,
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

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        let room = limit - data.count
        if room > 0 { data.append(chunk.prefix(room)) }
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
