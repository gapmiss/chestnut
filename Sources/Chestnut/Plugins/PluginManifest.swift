import Foundation

enum PluginInputType: String, Codable, Sendable {
    case text, url, image, file, pdf, any
}

enum PluginOutputMode: String, Codable, Sendable {
    case capture, save, clipboard, notify, structured
}

struct PluginManifest: Sendable {
    static let maxAPI = 1

    let api: Int
    let name: String
    let description: String
    let accepts: [PluginInputType]
    let output: PluginOutputMode
    let script: String
    let timeout: TimeInterval
    let scriptURL: URL
}

enum ManifestLoadResult: Sendable {
    case ok(PluginManifest)
    case apiTooHigh(name: String, api: Int)
    case invalid
}

extension PluginManifest {
    fileprivate struct Raw: Codable {
        let api: Int
        let name: String
        let description: String?
        let accepts: [String]
        let output: String
        let script: String
        let timeout: Double?
    }

    static func load(from directory: URL) -> ManifestLoadResult {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else { return .invalid }

        if raw.api > maxAPI {
            return .apiTooHigh(name: raw.name, api: raw.api)
        }

        guard let outputMode = PluginOutputMode(rawValue: raw.output) else {
            return .invalid
        }

        let accepts = raw.accepts.compactMap { PluginInputType(rawValue: $0) }
        guard !accepts.isEmpty else { return .invalid }

        let scriptURL = directory.appendingPathComponent(raw.script)
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            return .invalid
        }

        return .ok(PluginManifest(
            api: raw.api,
            name: raw.name,
            description: raw.description ?? "",
            accepts: accepts,
            output: outputMode,
            script: raw.script,
            timeout: raw.timeout ?? 10,
            scriptURL: scriptURL
        ))
    }
}

struct PluginEnvelope: Codable, Sendable {
    let action: String
    let content: String?
    let filename: String?
    let vault: String?
    let folder: String?
    let notify: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        vault = try c.decodeIfPresent(String.self, forKey: .vault)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        notify = try c.decodeIfPresent(String.self, forKey: .notify)
    }
}
