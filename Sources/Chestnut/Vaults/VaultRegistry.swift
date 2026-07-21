import Foundation

/// One known vault. Identity is the path — names collide in the real world
/// (this machine alone has three vaults named "test-vault").
struct Vault: Equatable, Sendable {
    let path: String
    let lastOpened: Date
    let isOpen: Bool

    var name: String { (path as NSString).lastPathComponent }

    /// Path with the home directory abbreviated, for display next to the name
    /// (disambiguates duplicate names in the palette).
    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Reads Obsidian's vault list from `obsidian.json` and watches it for changes.
/// Strictly read-only — we never write to anything Obsidian owns.
@MainActor
final class VaultRegistry {
    /// Fired on start and whenever the vault list changes, with vaults sorted
    /// palette-style: open vaults first, then most recently opened.
    var onChange: (([Vault]) -> Void)?

    private(set) var vaults: [Vault] = []

    private let fileURL: URL
    private var source: DispatchSourceFileSystemObject?

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
    }

    init(fileURL: URL = VaultRegistry.defaultFileURL) {
        self.fileURL = fileURL
    }

    func start() {
        reload(notifyEvenIfUnchanged: true)
        armWatcher()
    }

    // MARK: - Parsing (pure, fixture-testable)

    private struct RegistryFile: Decodable {
        struct Entry: Decodable {
            let path: String
            let ts: Double?
            let open: Bool?
        }
        let vaults: [String: Entry]
    }

    /// Parse `obsidian.json` data into vaults, deduplicated by path and sorted
    /// open-first then most-recent. Throws on malformed JSON.
    nonisolated static func parse(_ data: Data) throws -> [Vault] {
        let file = try JSONDecoder().decode(RegistryFile.self, from: data)
        var byPath: [String: Vault] = [:]
        for entry in file.vaults.values {
            let vault = Vault(
                path: entry.path,
                lastOpened: Date(timeIntervalSince1970: (entry.ts ?? 0) / 1000),
                isOpen: entry.open ?? false
            )
            if let existing = byPath[entry.path],
               existing.lastOpened >= vault.lastOpened, !vault.isOpen {
                continue
            }
            byPath[entry.path] = vault
        }
        return byPath.values.sorted {
            if $0.isOpen != $1.isOpen { return $0.isOpen }
            return $0.lastOpened > $1.lastOpened
        }
    }

    /// The pinned vault (matched by path) hoisted to the front, remaining
    /// order untouched. No pin or a pin that left the registry = unchanged.
    nonisolated static func pinnedFirst(_ vaults: [Vault], pinnedPath: String?) -> [Vault] {
        guard let pinnedPath,
              let index = vaults.firstIndex(where: { $0.path == pinnedPath })
        else { return vaults }
        var result = vaults
        result.insert(result.remove(at: index), at: 0)
        return result
    }

    // MARK: - Live reload

    private func reload(notifyEvenIfUnchanged: Bool = false) {
        let parsed: [Vault]
        do {
            parsed = try Self.parse(try Data(contentsOf: fileURL))
        } catch {
            // Transient states (mid-rewrite, Obsidian never installed) are
            // expected; keep the last good list rather than flashing empty.
            NSLog("VaultRegistry: could not read %@: %@", fileURL.path, error.localizedDescription)
            if notifyEvenIfUnchanged { onChange?(vaults) }
            return
        }
        guard parsed != vaults || notifyEvenIfUnchanged else { return }
        let oldPaths = Set(vaults.map(\.path))
        vaults = parsed
        let newPaths = Set(vaults.map(\.path))
        let added = newPaths.subtracting(oldPaths)
        let removed = oldPaths.subtracting(newPaths)
        if DebugLog.enabled {
            DebugLog.log("vault registry: reload — \(vaults.count) vault(s), \(vaults.filter(\.isOpen).count) open")
            if !added.isEmpty { DebugLog.log("vault registry:   added: \(added)") }
            if !removed.isEmpty { DebugLog.log("vault registry:   removed: \(removed)") }
        }
        onChange?(vaults)
    }

    /// Obsidian rewrites the file atomically (replace), so the vnode we watch
    /// disappears on every change: on delete/rename we re-open and re-arm.
    private func armWatcher() {
        source?.cancel()
        source = nil

        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else {
            // File missing (Obsidian not installed / first run): retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.armWatcher()
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let rearm = source.data.contains(.delete) || source.data.contains(.rename)
            self.reload()
            if rearm { self.armWatcher() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
}
