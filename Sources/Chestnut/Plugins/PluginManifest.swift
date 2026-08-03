import Foundation

// `CaseIterable` on both is for `make check`, which holds the published guide
// to these lists. `pdf` and `any` were real cases that appeared nowhere in the
// docs, so a plugin author had no way to discover them.
enum PluginInputType: String, Codable, Sendable, CaseIterable {
    case text, url, image, file, pdf, folder, any
}

enum PluginOutputMode: String, Codable, Sendable, CaseIterable {
    case capture, save, clipboard, notify, structured
}

struct PluginManifest: Sendable {
    static let maxAPI = 1

    let api: Int
    let name: String
    let description: String
    let accepts: [PluginInputType]
    let extensions: Set<String>
    let output: PluginOutputMode
    let script: String
    let timeout: TimeInterval
    /// Opt-in: treat each line of stdout as one complete JSON envelope, handled
    /// as it arrives, instead of the whole of stdout being one envelope.
    ///
    /// Opt-in and not the new default for `structured`, which is not a
    /// stylistic preference. An existing `structured` plugin emits a single
    /// JSON object that may be pretty-printed across many lines — the shipped
    /// examples do exactly that — so splitting on newlines unconditionally
    /// would break every one of them, silently, at upgrade time.
    let stream: Bool
    let scriptURL: URL

    func matchesFile(type: PluginInputType, ext: String) -> Bool {
        guard accepts.contains(type) || accepts.contains(.any) else {
            return false
        }
        if extensions.isEmpty { return true }
        return extensions.contains(ext.lowercased())
    }
}

enum ManifestLoadResult: Sendable {
    case ok(PluginManifest)
    case apiTooHigh(name: String, api: Int)
    /// Rejected, with a reason to log. A rejected plugin has no menu entry and
    /// no notice, so without this the author sees nothing at all — the failure
    /// mode a `command`/`script` typo in the published guide used to produce.
    case invalid(reason: String)
}

extension PluginManifest {
    fileprivate struct Raw: Codable {
        let api: Int
        let name: String
        let description: String?
        let accepts: [String]
        let extensions: [String]?
        let output: String
        let script: String
        let timeout: Double?
        let stream: Bool?

        // Spelled out rather than synthesized so the names can be enumerated.
        // Adding a property without a case here fails to compile, which is what
        // keeps `manifestFields` honest.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case api, name, description, accepts, extensions, output, script,
                 timeout, stream
        }
    }

    /// Every field the parser reads, for `make check` to hold the published
    /// reference table and examples to.
    ///
    /// The guide documented `command` where the parser requires `script`, in
    /// the reference table *and* in both copy-pasteable examples. A manifest
    /// missing `script` fails to decode, `rescan` swallows the `.invalid`, and
    /// the plugin simply never appears — no notice, no log line. So the
    /// documented on-ramp to the whole plugin system was broken with no
    /// diagnostic anywhere, and it took an audit to notice (M4). Nothing about
    /// that failure was detectable at runtime; comparing the two lists is.
    static var manifestFields: Set<String> {
        Set(Raw.CodingKeys.allCases.map(\.rawValue))
    }

    /// Manifest timeouts are clamped rather than trusted, like everything
    /// else read from disk: 0 (or negative) schedules the SIGTERM at launch,
    /// so the plugin dies instantly and every run reports "timed out"; a huge
    /// value keeps the pet chewing on a hung plugin effectively forever.
    ///
    /// **`0` keeps clamping up to one second, and never becomes "no timeout".**
    /// Reversing that meaning would turn a manifest that is merely broken
    /// today — one whose plugin is killed almost immediately — into an
    /// unkillable one on the next upgrade, without its author touching a thing.
    ///
    /// The ceiling is four hours, up from five minutes. Five minutes ruled out
    /// the work this feature exists for: transcribing a 90-minute recording on
    /// CPU takes 10 to 60 minutes, and OCR or a batch conversion of a folder can
    /// run longer. Four hours covers those with room to spare.
    ///
    /// There is still a ceiling, and there deliberately is no way to remove it.
    /// The Running Plugins submenu is discoverable UI, not a guarantee: it works
    /// only for a user who notices something is running and thinks to stop it.
    /// An unbounded timeout would let a plugin nobody remembers chew until the
    /// machine is rebooted.
    static let timeoutRange: ClosedRange<TimeInterval> = 1...14400
    static let defaultTimeout: TimeInterval = 10

    static func clampedTimeout(_ raw: Double?) -> TimeInterval {
        guard let raw else { return defaultTimeout }
        return raw.clamped(to: timeoutRange)
    }

    static func load(from directory: URL) -> ManifestLoadResult {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .invalid(reason: "manifest.json is missing or unreadable")
        }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            // The decoder's message names the offending key, which is the
            // whole point: a manifest using the wrong field name should say so.
            return .invalid(reason: "manifest.json did not parse: \(error)")
        }

        if raw.api > maxAPI {
            return .apiTooHigh(name: raw.name, api: raw.api)
        }

        guard let outputMode = PluginOutputMode(rawValue: raw.output) else {
            return .invalid(reason: "unknown output mode \"\(raw.output)\"")
        }

        let accepts = raw.accepts.compactMap { PluginInputType(rawValue: $0) }
        guard !accepts.isEmpty else {
            return .invalid(
                reason: "no recognized input type in accepts \(raw.accepts)")
        }

        let scriptURL = directory.appendingPathComponent(raw.script)
            .standardized
        let dirPrefix = directory.standardized.path + "/"
        guard scriptURL.path.hasPrefix(dirPrefix) else {
            return .invalid(
                reason: "script \"\(raw.script)\" resolves outside the plugin folder")
        }
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            return .invalid(
                reason: "script \"\(raw.script)\" is missing or not executable (chmod +x)")
        }

        let exts = Set((raw.extensions ?? []).map { $0.lowercased() })

        let timeout = clampedTimeout(raw.timeout)
        if let rawTimeout = raw.timeout, rawTimeout != timeout {
            NSLog("Plugin \"%@\": timeout %g is outside %g–%g, using %g",
                  raw.name, rawTimeout,
                  timeoutRange.lowerBound, timeoutRange.upperBound, timeout)
        }

        // Streaming is a way of reading structured envelopes, so it means
        // nothing without them. A plugin that asks for it in any other output
        // mode gets a log line and a plain run, rather than being rejected: the
        // same forgiving treatment an out-of-range timeout gets, and the
        // alternative is a plugin that vanishes from the menu over a field it
        // did not need.
        var stream = raw.stream ?? false
        if stream, outputMode != .structured {
            NSLog("Plugin \"%@\": \"stream\" needs output \"structured\"; ignoring it",
                  raw.name)
            stream = false
        }

        return .ok(PluginManifest(
            api: raw.api,
            name: raw.name,
            description: raw.description ?? "",
            accepts: accepts,
            extensions: exts,
            output: outputMode,
            script: raw.script,
            timeout: timeout,
            stream: stream,
            scriptURL: scriptURL
        ))
    }
}

struct PluginAttachment: Codable, Sendable {
    let source: String
    let filename: String
}

struct PluginEnvelope: Codable, Sendable {
    let action: String
    let content: String?
    let filename: String?
    let vault: String?
    let folder: String?
    let notify: String?
    let attachments: [PluginAttachment]?

    /// Same reason as `Raw.CodingKeys`: enumerable, and a new field that skips
    /// this enum won't compile. The envelope docs were wrong about `vault`,
    /// `filename` and `attachments` at once (M5).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case action, content, filename, vault, folder, notify, attachments
    }

    static var envelopeFields: Set<String> {
        Set(CodingKeys.allCases.map(\.rawValue))
    }
}
