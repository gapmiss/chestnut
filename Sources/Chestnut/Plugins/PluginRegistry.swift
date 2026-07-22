import CoreServices
import Foundation

@MainActor
final class PluginRegistry {
    var onChange: (() -> Void)?
    var onAPINotice: ((String, Int) -> Void)?

    private(set) var plugins: [PluginManifest] = []
    private(set) var pluginDirs: [String: URL] = [:]

    private var stream: FSEventStreamRef?
    private let directory: URL

    static var pluginsDirectory: URL {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/chestnut/plugins")
        return config
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.pluginsDirectory
    }

    func start() {
        let dir = directory
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        rescan()
        watchDirectory(dir)
        DebugLog.log("plugin registry: started, \(plugins.count) plugin(s) at \(dir.path)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    var disabled: Set<String> = []

    func pluginsAccepting(_ type: PluginInputType) -> [(PluginManifest, URL)] {
        plugins.compactMap { manifest in
            guard !disabled.contains(manifest.name) else { return nil }
            guard manifest.accepts.contains(type) || manifest.accepts.contains(.any)
            else { return nil }
            guard let dir = pluginDirs[manifest.name] else { return nil }
            return (manifest, dir)
        }
    }

    func pluginsAccepting(
        _ type: PluginInputType, ext: String
    ) -> [(PluginManifest, URL)] {
        plugins.compactMap { manifest in
            guard !disabled.contains(manifest.name) else { return nil }
            guard manifest.matchesFile(type: type, ext: ext) else { return nil }
            guard let dir = pluginDirs[manifest.name] else { return nil }
            return (manifest, dir)
        }
    }

    func rescan() {
        let dir = directory
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            plugins = []
            pluginDirs = [:]
            onChange?()
            return
        }

        var newPlugins: [PluginManifest] = []
        var newDirs: [String: URL] = [:]

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }

            switch PluginManifest.load(from: entry) {
            case .ok(let manifest):
                if let existing = newDirs[manifest.name] {
                    NSLog("PluginRegistry: skipping duplicate plugin \"\(manifest.name)\" at \(entry.path) (already loaded from \(existing.path))")
                } else {
                    newPlugins.append(manifest)
                    newDirs[manifest.name] = entry
                }
            case .apiTooHigh(let name, let api):
                onAPINotice?(name, api)
            case .invalid:
                break
            }
        }

        let wasEmpty = plugins.isEmpty
        let added = newPlugins.filter { p in !plugins.contains(where: { $0.name == p.name }) }
        let removed = plugins.filter { p in !newPlugins.contains(where: { $0.name == p.name }) }
        plugins = newPlugins
        pluginDirs = newDirs
        if DebugLog.enabled, !added.isEmpty || !removed.isEmpty || wasEmpty {
            DebugLog.log("plugin registry: rescan — added=\(added.map(\.name)) removed=\(removed.map(\.name)) total=\(plugins.count)")
            if wasEmpty {
                for p in plugins {
                    DebugLog.log("plugin registry:   \(p.name) at \(pluginDirs[p.name]?.path ?? "?")")
                }
            }
        }
        onChange?()
    }

    private func watchDirectory(_ dir: URL) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            pluginRegistryCallback,
            &context,
            [dir.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            NSLog("PluginRegistry: FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}

private let pluginRegistryCallback: FSEventStreamCallback = {
    _, info, _, _, _, _ in
    guard let info else { return }
    let registry = Unmanaged<PluginRegistry>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated {
        registry.rescan()
    }
}
