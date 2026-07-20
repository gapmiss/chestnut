import CoreServices
import Foundation

/// Watches vault roots via FSEvents and turns bursts of `.md` edits into
/// debounced writing-activity signals, classified by vault path.
/// Read-only: it only observes; `.obsidian/` and `.trash/` are ignored.
@MainActor
final class VaultWatcher {
    /// Minimum gap between signals for the same vault.
    static let signalInterval: TimeInterval = 2

    /// Fired (at most every `signalInterval` per vault) with the vault path.
    var onWritingActivity: ((String) -> Void)?

    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    /// FSEvents reports symlink-resolved paths (e.g. /var → /private/var), so
    /// matching happens on resolved roots, mapped back to the vault path.
    private var vaultPathByResolvedRoot: [String: String] = [:]
    private var lastSignal: [String: Date] = [:]

    /// Start (or retarget) watching the given vault roots. No-op if unchanged.
    func watch(roots newRoots: [String]) {
        let existing = newRoots.filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != roots else { return }
        stop()
        roots = existing
        vaultPathByResolvedRoot = Dictionary(
            roots.map { (Self.canonicalPath($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            vaultWatcherCallback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,  // FSEvents-level coalescing latency (seconds)
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else {
            NSLog("VaultWatcher: FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        roots = []
    }

    fileprivate func handleEvents(paths: [String]) {
        let now = Date()
        for path in paths {
            guard path.hasSuffix(".md"),
                  let root = vaultRoot(containing: path),
                  let vaultPath = vaultPathByResolvedRoot[root],
                  now.timeIntervalSince(lastSignal[vaultPath] ?? .distantPast) >= Self.signalInterval
            else { continue }
            lastSignal[vaultPath] = now
            onWritingActivity?(vaultPath)
        }
    }

    /// Longest watched (resolved) root containing the path, unless the path
    /// sits inside vault housekeeping folders we must ignore.
    private func vaultRoot(containing path: String) -> String? {
        guard let root = vaultPathByResolvedRoot.keys
            .filter({ path.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count })
        else { return nil }
        let relative = path.dropFirst(root.count + 1)
        let ignored = relative.split(separator: "/").contains {
            $0 == ".obsidian" || $0 == ".trash"
        }
        return ignored ? nil : root
    }

    /// realpath(3): URL.resolvingSymlinksInPath() won't add the /private
    /// prefix (it strips it), so it can't match what FSEvents reports.
    private nonisolated static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// C callback: hops back onto the watcher (scheduled on the main queue).
private let vaultWatcherCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
    guard let info else { return }
    // kFSEventStreamCreateFlagUseCFTypes: eventPaths is a CFArray of CFStrings.
    guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
    let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated {
        watcher.handleEvents(paths: paths)
    }
}
