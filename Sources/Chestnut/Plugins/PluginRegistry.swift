import CoreServices
import Foundation

@MainActor
final class PluginRegistry {
    var onChange: (() -> Void)?
    var onAPINotice: ((String, Int) -> Void)?

    private(set) var plugins: [PluginManifest] = []
    private(set) var pluginDirs: [String: URL] = [:]

    private var stream: FSEventStreamRef?

    static var pluginsDirectory: URL {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/chestnut/plugins")
        return config
    }

    func start() {
        let dir = Self.pluginsDirectory
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        rescan()
        watchDirectory(dir)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func pluginsAccepting(_ type: PluginInputType) -> [(PluginManifest, URL)] {
        plugins.compactMap { manifest in
            guard manifest.accepts.contains(type) || manifest.accepts.contains(.any)
            else { return nil }
            guard let dir = pluginDirs[manifest.name] else { return nil }
            return (manifest, dir)
        }
    }

    func rescan() {
        let dir = Self.pluginsDirectory
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
                if newDirs[manifest.name] == nil {
                    newPlugins.append(manifest)
                    newDirs[manifest.name] = entry
                }
            case .apiTooHigh(let name, let api):
                onAPINotice?(name, api)
            case .invalid:
                break
            }
        }

        plugins = newPlugins
        pluginDirs = newDirs
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
