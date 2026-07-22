import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private let controller = PetController()
    private let registry = VaultRegistry()
    private let watcher = VaultWatcher()
    private let courier = Courier()
    private let journal: Journal<CourierOperation> = .deliveries
    private let captureJournal: Journal<CaptureRecord> = .captures
    private let hotkeys = HotkeyCenter()
    private let pluginRegistry = PluginRegistry()
    private var petWindow: PetWindow?
    /// The one panel on screen (Vault Hopper, courier destination picker,
    /// or capture bubble).
    private var palette: PetPanel?
    /// The one transient notice bubble; replaced by the next one.
    private var notice: NoticePanel?
    /// Draft text survives capture panel dismiss/reopen; cleared on submit.
    private var captureDraft = ""
    /// Vault picked in the capture panel survives dismiss/reopen too
    /// (session-only; a successful capture persists it via the config).
    private var captureTargetPath: String?

    /// Stateless; built per use so hand-edited config applies next launch.
    private var capture: Capture {
        Capture(
            inboxFileName: config.captureInboxName,
            captureFormat: config.captureFormat,
            captureFolder: config.captureFolder
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.configure(enabled: config.debug)
        DebugLog.log("config loaded from \(Config.fileURL.path)")
        UserDefaults.standard.set(300, forKey: "NSInitialToolTipDelay")
        if let custom = config.customThemes {
            SpriteTheme.registerCustomThemes(custom)
            DebugLog.log("config: registered \(custom.count) custom theme(s): \(custom.map(\.id))")
        }
        if SpriteTheme.theme(id: config.petTheme).id != config.petTheme {
            DebugLog.log("config: theme \"\(config.petTheme)\" invalid, falling back to default")
            config.petTheme = SpriteTheme.defaultID
        }
        openPetWindow()
        controller.start()

        watcher.onWritingActivity = { [weak self] _ in
            self?.controller.noteWritingActivity()
        }
        registry.onChange = { [weak self] vaults in
            self?.watcher.watch(roots: vaults.filter(\.isOpen).map(\.path))
        }
        registry.start()

        hotkeys.onCapture = { [weak self] in
            self?.toggleCapture()
        }
        hotkeys.onHopper = { [weak self] in
            self?.toggleHopper()
        }
        hotkeys.onNotice = { [weak self] in
            self?.notice?.performAction()
        }
        hotkeys.onPaste = { [weak self] in
            self?.handlePasteHotkey()
        }
        hotkeys.start(config: config.hotkeys)

        pluginRegistry.onAPINotice = { [weak self] name, api in
            self?.showNotice(
                "Plugin \u{201C}\(name)\u{201D} requires api \(api)",
                "This version of Chestnut supports api \(PluginManifest.maxAPI)"
            )
        }
        pluginRegistry.disabled = config.disabledPlugins
        pluginRegistry.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        pluginRegistry.stop()
    }

    private func openPetWindow() {
        let window = PetWindow(config: config, controller: controller)
        window.onConfigChange = { [weak self] newConfig in
            self?.config = newConfig
            newConfig.save()
        }
        window.onSelectSize = { [weak self] size in
            self?.changeSize(to: size)
        }
        window.onSelectTheme = { [weak self] id in
            self?.changeTheme(to: id)
        }
        window.onToggleHopper = { [weak self] in
            self?.toggleHopper()
        }
        window.resolveVaultByName = { [weak self] name in
            guard let vaults = self?.registry.vaults else { return nil }
            let matches = vaults.filter { $0.name == name }
            guard matches.count == 1 else { return nil }
            return matches[0].path
        }
        window.hasPluginForFileExt = { [weak self] type, ext in
            !(self?.pluginRegistry.pluginsAccepting(type, ext: ext).isEmpty ?? true)
        }
        window.onFilesDropped = { [weak self] urls, copy in
            self?.beginDelivery(of: urls, copy: copy)
        }
        window.onPluginDrop = { [weak self] type, input in
            self?.handlePluginInput(type: type, input: input)
        }
        window.canUndoDelivery = { [weak self] in
            self?.journal.last() != nil
        }
        window.onUndoDelivery = { [weak self] in
            self?.undoLastDelivery()
        }
        window.onCapture = { [weak self] in
            self?.toggleCapture()
        }
        window.canUndoCapture = { [weak self] in
            self?.captureJournal.last() != nil
        }
        window.onUndoCapture = { [weak self] in
            self?.undoLastCapture()
        }
        window.installedPlugins = { [weak self] in
            self?.pluginRegistry.plugins ?? []
        }
        window.isPluginEnabled = { [weak self] name in
            !(self?.config.disabledPlugins.contains(name) ?? false)
        }
        window.togglePlugin = { [weak self] name in
            guard let self else { return }
            if self.config.disabledPlugins.contains(name) {
                self.config.disabledPlugins.remove(name)
            } else {
                self.config.disabledPlugins.insert(name)
            }
            self.pluginRegistry.disabled = self.config.disabledPlugins
            self.config.save()
        }
        window.onOpenPluginsFolder = {
            let dir = PluginRegistry.pluginsDirectory
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(
                    at: dir, withIntermediateDirectories: true
                )
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
        }
        controller.onStateChange = { [weak window] state in
            window?.petScene.play(state)
        }
        window.orderFrontRegardless()
        petWindow = window
    }

    /// Rebuild the window at the new scale, keeping the pet's bottom-center put.
    private func changeSize(to size: Config.PetSize) {
        guard let old = petWindow else { return }
        palette?.dismiss()
        let oldFrame = old.frame
        let newSize = PetWindow.contentSize(for: size)
        config.size = size
        config.position = NSPoint(x: oldFrame.midX - newSize.width / 2, y: oldFrame.minY)
        config.save()
        old.close()
        openPetWindow()
    }

    /// Rebuild the window with the new theme's textures (same path as a size
    /// change; geometry is unchanged, so the position stays put).
    private func changeTheme(to id: String) {
        guard let old = petWindow else { return }
        palette?.dismiss()
        config.petTheme = id
        config.save()
        old.close()
        openPetWindow()
    }

    // MARK: - Vault Hopper

    /// Registry order (open-first/most-recent) with the pinned vault hoisted
    /// to the top, so it starts highlighted and owns ⌘1 in the capture panel.
    private func pinnedFirst(_ vaults: [Vault]) -> [Vault] {
        VaultRegistry.pinnedFirst(vaults, pinnedPath: config.pinnedVaultPath)
    }

    private func setPinnedVault(_ path: String?) {
        config.pinnedVaultPath = path
        config.save()
    }

    private func toggleHopper() {
        if palette is VaultPalettePanel {
            palette?.dismiss()
            return
        }
        DebugLog.log("hopper: opening with \(registry.vaults.count) vault(s)")
        presentPalette(
            VaultPalettePanel(
                vaults: pinnedFirst(registry.vaults),
                pinnedPath: config.pinnedVaultPath,
                onOpenDaily: { [weak self] vault in
                    self?.openDailyNote(in: vault)
                },
                onPinChange: { [weak self] path in
                    self?.setPinnedVault(path)
                }
            ) { vault in
                ObsidianBridge.openVault(path: vault.path)
            }
        )
    }

    /// ⌘⏎ in the Vault Hopper: open today's capture target. Read-only —
    /// when the note doesn't exist yet, open the vault instead and say so
    /// (hopping never creates notes; capture does).
    private func openDailyNote(in vault: Vault) {
        let vaultURL = URL(fileURLWithPath: vault.path)
        if let note = capture.existingDestination(inVault: vaultURL) {
            ObsidianBridge.openNote(path: note.path, vaultPath: vault.path)
        } else {
            ObsidianBridge.openVault(path: vault.path)
            showNotice("No note today yet in \(vault.name)", "Opened the vault instead")
        }
    }

    /// Show a panel anchored to the pet, with the open-lid pose held.
    private func presentPalette(_ panel: PetPanel) {
        guard let petWindow else { return }
        notice?.dismiss()
        notice = nil
        palette?.onClose = nil
        palette?.dismiss()
        panel.onClose = { [weak self] in
            self?.palette = nil
            self?.petWindow?.petScene.setOpenWide(false)
        }
        palette = panel
        petWindow.petScene.setOpenWide(true)
        panel.show(above: petWindow.frame)
    }

    // MARK: - Note Courier

    private func beginDelivery(of files: [URL], copy: Bool) {
        // Behavior changes here should be mirrored in the website's re-creation
        // (docs/chestnut.js, Note Courier demo).
        // Source vault: the registry vault containing every dropped file
        // (nil for drops from outside any vault — still deliverable).
        let sourceVault = registry.vaults.first { vault in
            files.allSatisfy { $0.path.hasPrefix(vault.path + "/") }
        }
        let destinations = registry.vaults.filter { $0.path != sourceVault?.path }
        guard !destinations.isEmpty else {
            petWindow?.petScene.setOpenWide(false)
            presentAlert(
                "Nowhere to deliver",
                "Chestnut couldn't find another vault in Obsidian's vault list."
            )
            return
        }
        presentPalette(
            VaultPalettePanel(
                vaults: pinnedFirst(destinations),
                placeholder: copy ? "Copy to vault…" : "Deliver to vault…",
                pinnedPath: config.pinnedVaultPath,
                onPinChange: { [weak self] path in
                    self?.setPinnedVault(path)
                }
            ) { [weak self] vault in
                self?.completeDelivery(of: files, to: vault, from: sourceVault, copy: copy)
            }
        )
    }

    private func completeDelivery(of files: [URL], to vault: Vault, from source: Vault?, copy: Bool) {
        palette?.dismiss()
        DebugLog.log("courier: delivering \(files.count) file(s) to \(vault.name) (\(vault.path))")
        do {
            let op = try courier.deliver(
                files: files,
                toVault: URL(fileURLWithPath: vault.path),
                sourceVault: source.map { URL(fileURLWithPath: $0.path) },
                copy: copy
            )
            do {
                try journal.append(op)
            } catch {
                NSLog("Journal append failed (delivery succeeded): %@", error.localizedDescription)
            }
            if DebugLog.enabled {
                for t in op.transfers {
                    DebugLog.log("courier:   \(t.from) → \(t.to)\(t.dedup ? " (dedup)" : "")")
                }
            }
            petWindow?.petScene.celebrateDelivery()
            controller.noteInteraction()
            guard !op.transfers.isEmpty else {
                showNotice("Already in \(vault.name)", "File already exists, skipped")
                return
            }
            let note = op.transfers.first { $0.to.hasSuffix(".md") }?.to
            let subtitle = op.transfers.count == 1
                ? (op.transfers[0].to as NSString).lastPathComponent
                : "\(op.transfers.count) files"
            showNotice(copy ? "Copied to \(vault.name)" : "Delivered to \(vault.name)", subtitle) {
                if let note {
                    ObsidianBridge.openNote(path: note, vaultPath: vault.path)
                } else if op.transfers.count == 1 {
                    ObsidianBridge.presentFile(path: op.transfers[0].to, vaultPath: vault.path)
                } else {
                    let folder = (op.transfers[0].to as NSString).deletingLastPathComponent
                    ObsidianBridge.presentFile(path: folder, vaultPath: vault.path)
                }
            }
        } catch {
            presentAlert("Delivery failed", error.localizedDescription)
        }
    }

    private func undoLastDelivery() {
        guard let op = journal.last() else { return }
        do {
            try courier.undo(op)
            try journal.removeLast()
            petWindow?.petScene.celebrateDelivery()
        } catch {
            presentAlert(
                "Undo failed",
                "\(error.localizedDescription)\nThe journal entry was kept; files may need a manual check."
            )
        }
    }

    // MARK: - Quick Capture

    private func toggleCapture() {
        if palette is CapturePanel {
            palette?.dismiss()
            return
        }
        guard !registry.vaults.isEmpty else {
            presentAlert(
                "Nowhere to capture",
                "Chestnut couldn't find any vault in Obsidian's vault list."
            )
            return
        }
        // Default target, best match first: the target of an in-progress
        // draft (they belong together — but only while a draft exists; the
        // panel remembers its target on every close, and without this guard
        // the pin could never win within a session), then the pinned vault,
        // then the last successful capture's vault, then the registry's
        // first (vaults arrive sorted open-first/most-recent).
        let vaults = pinnedFirst(registry.vaults)
        let draftTarget = captureDraft.isEmpty ? nil : captureTargetPath
        let target = vaults.first { $0.path == draftTarget }
            ?? vaults.first { $0.path == config.pinnedVaultPath }
            ?? vaults.first { $0.path == config.lastCaptureVaultPath }
            ?? vaults[0]
        presentPalette(
            CapturePanel(
                vaults: vaults, initialTarget: target, draft: captureDraft,
                onSubmit: { [weak self] text, vault in
                    self?.captureDraft = ""
                    self?.completeCapture(text, to: vault)
                },
                onDraftChange: { [weak self] draft in
                    self?.captureDraft = draft
                },
                onTargetChange: { [weak self] vault in
                    self?.captureTargetPath = vault.path
                }
            )
        )
    }

    private func completeCapture(_ text: String, to vault: Vault) {
        DebugLog.log("capture: to \(vault.name) (\(vault.path)), \(text.count) chars")
        config.lastCaptureVaultPath = vault.path
        config.save()
        let capture = self.capture
        let vaultURL = URL(fileURLWithPath: vault.path)
        let cliVaultName = cliName(for: vault)
        Task { [weak self] in
            let result = await Task.detached {
                Result { try capture.capture(text, toVault: vaultURL, cliVaultName: cliVaultName) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let record):
                DebugLog.log("capture: success → \(record.notePath), created=\(record.createdFile)")
                do {
                    try self.captureJournal.append(record)
                } catch {
                    NSLog("Capture journal append failed (capture succeeded): %@",
                          error.localizedDescription)
                }
                self.petWindow?.petScene.celebrateDelivery()
                self.controller.noteInteraction()
                self.showNotice(
                    "Captured to \(vault.name)",
                    (record.notePath as NSString).lastPathComponent
                ) {
                    ObsidianBridge.openNote(path: record.notePath, vaultPath: record.vaultPath)
                }
            case .failure(let error):
                self.presentAlert("Capture failed", error.localizedDescription)
            }
        }
    }

    /// The CLI targets vaults by *name* and talks to the live app, so it is
    /// only trusted when Obsidian is running, the vault is open, and no other
    /// registered vault shares the name (we key vaults by path — invariant).
    private func cliName(for vault: Vault) -> String? {
        guard vault.isOpen,
              registry.vaults.filter({ $0.name == vault.name }).count == 1,
              !NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").isEmpty
        else { return nil }
        return vault.name
    }

    private func undoLastCapture() {
        guard let record = captureJournal.last() else { return }
        do {
            try capture.undo(record)
            try captureJournal.removeLast()
            petWindow?.petScene.celebrateDelivery()
        } catch {
            presentAlert(
                "Undo capture failed",
                "\(error.localizedDescription)\nThe journal entry was kept; the note may need a manual check."
            )
        }
    }

    /// Success receipt above the pet: what happened and where, click (or the
    /// notice hotkey, registered only while the bubble is up) to follow
    /// through. Failures stay loud NSAlerts — never notices.
    private func showNotice(_ title: String, _ subtitle: String, onClick: (() -> Void)? = nil) {
        notice?.dismiss()
        guard let petWindow else { return }
        let hint = onClick == nil ? nil : HotkeySpec.display(config.hotkeys.notice)
        let panel = NoticePanel(title: title, subtitle: subtitle, hotkeyHint: hint, onClick: onClick)
        panel.onDismiss = { [weak self] in
            self?.hotkeys.setNoticeHotkeyEnabled(false)
        }
        panel.show(aboveSprite: petWindow.spriteFrame, for: config.noticeDuration)
        notice = panel
        if onClick != nil { hotkeys.setNoticeHotkeyEnabled(true) }
    }

    // MARK: - Plugins

    private func handlePasteHotkey() {
        guard let classified = PluginDispatch.classify(.general) else { return }
        handlePluginInput(type: classified.0, input: classified.1)
    }

    private func handlePluginInput(
        type: PluginInputType, input: PluginRunner.Input
    ) {
        let matches: [(PluginManifest, URL)]
        if let path = input.filePath {
            let ext = URL(fileURLWithPath: path).pathExtension
            matches = pluginRegistry.pluginsAccepting(type, ext: ext)
        } else {
            matches = pluginRegistry.pluginsAccepting(type)
        }
        DebugLog.log("plugin input: type=\(type.rawValue), \(matches.count) matching plugin(s): \(matches.map(\.0.name))")
        switch matches.count {
        case 0:
            petWindow?.petScene.setOpenWide(false)
        case 1:
            runPlugin(
                manifest: matches[0].0, dir: matches[0].1, input: input
            )
        default:
            presentPalette(
                PluginPalettePanel(plugins: matches) { [weak self] manifest, dir in
                    self?.runPlugin(
                        manifest: manifest, dir: dir, input: input
                    )
                }
            )
        }
    }

    private func runPlugin(
        manifest: PluginManifest, dir: URL, input: PluginRunner.Input
    ) {
        DebugLog.log("plugin run: \(manifest.name) at \(dir.path)")
        palette?.dismiss()
        petWindow?.petScene.setChewing(true)
        let tempPath = input.filePath
        Task { [weak self] in
            defer {
                if let tempPath,
                    tempPath.hasPrefix(
                        NSTemporaryDirectory() + "chestnut-plugins/")
                {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
            }
            do {
                let raw = try await PluginRunner.run(
                    manifest: manifest, pluginDir: dir, input: input
                )
                DebugLog.log("plugin run: \(manifest.name) exited \(raw.exitCode), stdout=\(raw.stdout.count) bytes, stderr=\(raw.stderr.prefix(200))")
                let result = try PluginRunner.interpret(
                    result: raw, manifest: manifest
                )
                DebugLog.log("plugin result: action=\(result.action.rawValue), content=\(result.content.count) bytes, attachments=\(result.attachments?.count ?? 0)")
                self?.petWindow?.petScene.setChewing(false)
                self?.handlePluginResult(result)
            } catch let error as PluginError {
                self?.petWindow?.petScene.setChewing(false)
                self?.handlePluginError(error)
            } catch {
                self?.petWindow?.petScene.setChewing(false)
                self?.handlePluginError(
                    .nonZeroExit(error.localizedDescription))
            }
        }
    }

    private func handlePluginResult(_ result: PluginRunner.InterpretedResult) {
        switch result.action {
        case .capture:
            captureDraft = result.content
            toggleCapture()
        case .save:
            savePluginOutput(result)
        case .clipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.content, forType: .string)
            petWindow?.petScene.celebrateDelivery()
            controller.noteInteraction()
            showNotice("Copied to clipboard", result.notifyText ?? "")
        case .notify:
            petWindow?.petScene.celebrateDelivery()
            controller.noteInteraction()
            showNotice(
                result.content.isEmpty ? "Plugin completed" : result.content,
                result.notifyText ?? ""
            )
        case .structured:
            break
        }
    }

    private func savePluginOutput(_ result: PluginRunner.InterpretedResult) {
        let filename = result.filename ?? "untitled.md"
        let content = result.content
        let folder = result.folder
        let attachments = result.attachments ?? []

        func save(to vault: Vault) {
            var dir = URL(fileURLWithPath: vault.path)
            if let folder, !folder.isEmpty {
                dir = dir.appendingPathComponent(folder)
            }
            let noteURL = dir.appendingPathComponent(filename)
            let allURLs = [noteURL] + attachments.map {
                dir.appendingPathComponent($0.filename)
            }
            for url in allURLs {
                guard Courier.isContained(url, inVault: vault.path) else {
                    presentAlert(
                        "Plugin save failed",
                        "Target path would escape the vault root or write inside .obsidian/."
                    )
                    return
                }
            }
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true
                )
                let url = Courier.availableURL(for: noteURL)
                try content.write(
                    to: url, atomically: true, encoding: .utf8
                )
                for att in attachments {
                    let src = URL(fileURLWithPath: att.source)
                        .standardizedFileURL
                    let dest = Courier.availableURL(
                        for: dir.appendingPathComponent(att.filename)
                    )
                    try FileManager.default.copyItem(at: src, to: dest)
                }
                petWindow?.petScene.celebrateDelivery()
                controller.noteInteraction()
                showNotice(
                    "Saved to \(vault.name)",
                    url.lastPathComponent
                ) {
                    ObsidianBridge.openNote(
                        path: url.path, vaultPath: vault.path
                    )
                }
            } catch {
                presentAlert(
                    "Plugin save failed", error.localizedDescription
                )
            }
        }

        let hint = result.vaultHint
        if hint == "ask" || hint == nil {
            let vaults = pinnedFirst(registry.vaults)
            guard !vaults.isEmpty else {
                presentAlert(
                    "Nowhere to save",
                    "No vaults found in Obsidian's vault list."
                )
                return
            }
            var saved = false
            let panel = VaultPalettePanel(
                vaults: vaults,
                placeholder: "Save to vault\u{2026}",
                pinnedPath: config.pinnedVaultPath,
                onPinChange: { [weak self] path in
                    self?.setPinnedVault(path)
                }
            ) { vault in
                saved = true
                save(to: vault)
            }
            presentPalette(panel)
            let oldClose = panel.onClose
            panel.onClose = { [weak self] in
                oldClose?()
                guard !saved else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
                self?.showNotice(
                    "Copied to clipboard",
                    "Plugin output saved to clipboard"
                )
            }
        } else if hint == "pinned" {
            let vault = registry.vaults.first {
                $0.path == config.pinnedVaultPath
            } ?? registry.vaults.first
            if let vault { save(to: vault) }
        } else if hint == "last" {
            let vault = registry.vaults.first {
                $0.path == config.lastCaptureVaultPath
            } ?? registry.vaults.first
            if let vault { save(to: vault) }
        } else if let hint {
            if let vault = registry.vaults.first(where: {
                $0.path == hint
            }) {
                save(to: vault)
            } else {
                presentAlert(
                    "Unknown vault",
                    "No vault found at: \(hint)"
                )
            }
        }
    }

    private func handlePluginError(_ error: PluginError) {
        showNotice("Plugin error", error.localizedDescription)
    }

    private func presentAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
