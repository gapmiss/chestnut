import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private var state = AppState.load()
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
    /// Attachments queued by a plugin's structured capture; copied on submit.
    private var captureAttachments: [PluginAttachment] = []
    /// Vault picked in the capture panel survives dismiss/reopen too
    /// (session-only; a successful capture persists it via the config).
    private var captureTargetPath: String?
    /// Temp input parked behind the plugin picker. If the picker closes
    /// without a plugin taking the input (Esc, or another palette replacing
    /// it), the file is garbage and the next palette close deletes it;
    /// `runPlugin` claims it for the input it runs, and its own cleanup takes
    /// over from there.
    private var pendingPluginTempPath: String?

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
        DebugLog.log("state loaded from \(AppState.fileURL.path)")
        if let other = otherRunningInstance() {
            DebugLog.log("another instance is running (pid \(other.processIdentifier)); quitting")
            presentAlert(
                "Chestnut is already running",
                "Another copy is running from \(other.bundleURL?.path ?? "an unknown location"). "
                    + "Two copies would fight over the same journals and settings, so this one is quitting."
            )
            NSApp.terminate(nil)
            return
        }
        // Everything under $TMPDIR/chestnut-plugins/ is a previous session's
        // parked input — a cancelled plugin picker or a capture draft that
        // was never submitted. Nothing this session has run yet, so the whole
        // directory is stale. (Runs after the single-instance guard so a
        // bounced second launch can't sweep the live instance's files.)
        try? FileManager.default.removeItem(
            atPath: NSTemporaryDirectory() + "chestnut-plugins")
        // Gives new users a documented file to edit; never touches an existing one.
        config.createIfMissing()
        UserDefaults.standard.set(300, forKey: "NSInitialToolTipDelay")
        if let custom = config.customThemes {
            SpriteTheme.registerCustomThemes(custom)
            DebugLog.log("config: registered \(custom.count) custom theme(s): \(custom.map(\.id))")
        }
        if SpriteTheme.theme(id: state.petTheme).id != state.petTheme {
            DebugLog.log("config: theme \"\(state.petTheme)\" invalid, falling back to default")
            state.petTheme = SpriteTheme.defaultID
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
        hotkeys.onMenu = { [weak self] in
            self?.petWindow?.showMenuFromHotkey()
        }
        hotkeys.onMenuHotkeyFailure = { [weak self] binding, reason in
            let pretty = HotkeySpec.display(binding) ?? "\u{201C}\(binding)\u{201D}"
            self?.showNotice(
                "Menu hotkey \(pretty) didn't register",
                "\(reason). Right-click still opens the menu; rebind \u{201C}menu\u{201D} in config.json."
            )
        }
        hotkeys.start(config: config.hotkeys)

        pluginRegistry.onAPINotice = { [weak self] name, api in
            self?.showNotice(
                "Plugin \u{201C}\(name)\u{201D} requires api \(api)",
                "This version of Chestnut supports api \(PluginManifest.maxAPI)"
            )
        }
        pluginRegistry.disabled = state.disabledPlugins
        pluginRegistry.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        pluginRegistry.stop()
    }

    private func openPetWindow() {
        let window = PetWindow(state: state, config: config, controller: controller)
        window.onStateChange = { [weak self] newState in
            self?.state = newState
            newState.save()
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
        window.hasPluginForType = { [weak self] type in
            !(self?.pluginRegistry.pluginsAccepting(type).isEmpty ?? true)
        }
        window.onFilesDropped = { [weak self] urls, copy in
            self?.beginDelivery(of: urls, copy: copy)
        }
        window.onPluginDrop = { [weak self] type, input in
            self?.handlePluginInput(type: type, input: input)
        }
        window.undoDeliveryRow = { [weak self] in
            self?.journal.last().map { UndoRow(subtitle: $0.undoMenuSubtitle) }
        }
        window.onUndoDelivery = { [weak self] in
            self?.undoLastDelivery()
        }
        window.onCapture = { [weak self] in
            self?.toggleCapture()
        }
        window.undoCaptureRow = { [weak self] in
            self?.captureJournal.last().map { UndoRow(subtitle: $0.undoMenuSubtitle) }
        }
        window.onUndoCapture = { [weak self] in
            self?.undoLastCapture()
        }
        window.installedPlugins = { [weak self] in
            self?.pluginRegistry.plugins ?? []
        }
        window.isPluginEnabled = { [weak self] name in
            !(self?.state.disabledPlugins.contains(name) ?? false)
        }
        window.togglePlugin = { [weak self] name in
            guard let self else { return }
            if self.state.disabledPlugins.contains(name) {
                self.state.disabledPlugins.remove(name)
            } else {
                self.state.disabledPlugins.insert(name)
            }
            self.pluginRegistry.disabled = self.state.disabledPlugins
            self.state.save()
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
        window.onEditConfiguration = { [weak self] in
            self?.openConfigForEditing()
        }
        window.onMenuTrackingChange = { [weak self] tracking in
            self?.hotkeys.setMenuHotkeyEnabled(!tracking)
        }
        controller.onStateChange = { [weak window] state in
            window?.petScene.play(state)
        }
        window.orderFrontRegardless()
        petWindow = window
    }

    /// Rebuild the window at the new scale, keeping the pet's bottom-center put.
    private func changeSize(to size: AppState.PetSize) {
        guard let old = petWindow else { return }
        palette?.dismiss()
        let oldFrame = old.frame
        let newSize = PetWindow.contentSize(for: size)
        state.size = size
        state.position = NSPoint(x: oldFrame.midX - newSize.width / 2, y: oldFrame.minY)
        state.save()
        old.close()
        openPetWindow()
    }

    /// Rebuild the window with the new theme's textures (same path as a size
    /// change; geometry is unchanged, so the position stays put).
    private func changeTheme(to id: String) {
        guard let old = petWindow else { return }
        palette?.dismiss()
        state.petTheme = id
        state.save()
        old.close()
        openPetWindow()
    }

    // MARK: - Vault Hopper

    /// Registry order (open-first/most-recent) with the pinned vault hoisted
    /// to the top, so it starts highlighted and owns ⌘1 in the capture panel.
    private func pinnedFirst(_ vaults: [Vault]) -> [Vault] {
        VaultRegistry.pinnedFirst(vaults, pinnedPath: state.pinnedVaultPath)
    }

    private func setPinnedVault(_ path: String?) {
        state.pinnedVaultPath = path
        state.save()
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
                pinnedPath: state.pinnedVaultPath,
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
            self?.discardPendingPluginTemp()
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
                pinnedPath: state.pinnedVaultPath,
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
        // Deliveries run off the main actor, for the same reason captures do
        // and more so: a cross-volume place() is a full byte copy, resolve()
        // walks the whole source vault once per unresolved reference, and
        // contentsEqual byte-compares every deduped file. Run here, any of the
        // three freezes the pet, the menu and every hotkey until it finishes.
        // The chewing pose says the work is still going, as the plugin runner
        // does for the same reason.
        petWindow?.petScene.setChewing(true)
        let courier = self.courier
        let destVault = URL(fileURLWithPath: vault.path)
        let sourceVault = source.map { URL(fileURLWithPath: $0.path) }
        Task { [weak self] in
            let result = await Task.detached {
                Result {
                    try courier.deliver(
                        files: files, toVault: destVault,
                        sourceVault: sourceVault, copy: copy
                    )
                }
            }.value
            guard let self else { return }
            self.petWindow?.petScene.setChewing(false)
            switch result {
            case .success(let op):
                do {
                    try self.journal.append(op)
                } catch {
                    NSLog("Journal append failed (delivery succeeded): %@",
                          error.localizedDescription)
                }
                if DebugLog.enabled {
                    for t in op.transfers {
                        DebugLog.log("courier:   \(t.from) → \(t.to)\(t.dedup ? " (dedup)" : "")")
                    }
                }
                self.petWindow?.petScene.celebrateDelivery()
                self.controller.noteInteraction()
                guard !op.transfers.isEmpty else {
                    self.showNotice("Already in \(vault.name)", "File already exists, skipped")
                    return
                }
                let note = op.transfers.first { $0.to.hasSuffix(".md") }?.to
                let subtitle = op.transfers.count == 1
                    ? (op.transfers[0].to as NSString).lastPathComponent
                    : "\(op.transfers.count) files"
                self.showNotice(
                    copy ? "Copied to \(vault.name)" : "Delivered to \(vault.name)", subtitle
                ) {
                    if let note {
                        ObsidianBridge.openNote(path: note, vaultPath: vault.path)
                    } else if op.transfers.count == 1 {
                        ObsidianBridge.presentFile(path: op.transfers[0].to, vaultPath: vault.path)
                    } else {
                        let folder = (op.transfers[0].to as NSString).deletingLastPathComponent
                        ObsidianBridge.presentFile(path: folder, vaultPath: vault.path)
                    }
                }
            case .failure(let error):
                self.presentAlert("Delivery failed", error.localizedDescription)
            }
        }
    }

    private func undoLastDelivery() {
        guard let op = journal.last() else { return }
        do {
            try courier.undo(op)
            try journal.removeLast()
            petWindow?.petScene.celebrateDelivery()
        } catch {
            // A partial undo did reverse something, so it gets the honest
            // title and the alert drops its "nothing was changed" promise.
            let partial: Bool
            if case CourierError.partiallyUndone = error { partial = true } else { partial = false }
            let title = partial ? "Undo finished part-way" : "Undo failed"
            if presentUndoFailure(title, error.localizedDescription, changedFiles: partial) {
                discardUndoRecord { try journal.removeLast() }
            }
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
            ?? vaults.first { $0.path == state.pinnedVaultPath }
            ?? vaults.first { $0.path == state.lastCaptureVaultPath }
            ?? vaults[0]
        presentPalette(
            CapturePanel(
                vaults: vaults, initialTarget: target, draft: captureDraft,
                onSubmit: { [weak self] text, vault in
                    self?.captureDraft = ""
                    let attachments = self?.captureAttachments ?? []
                    self?.captureAttachments = []
                    self?.completeCapture(text, to: vault, attachments: attachments)
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

    private func completeCapture(
        _ text: String, to vault: Vault,
        attachments: [PluginAttachment] = []
    ) {
        DebugLog.log("capture: to \(vault.name) (\(vault.path)), \(text.count) chars, attachments=\(attachments.count)")
        state.lastCaptureVaultPath = vault.path
        state.save()

        // Only files the note refers to are copied; see
        // partitionAttachmentsByReference. A draft that survived a dismissed
        // panel and was then rewritten carries none of the old plugin's files.
        // The split is pure — nothing is copied or deleted until the note is
        // safely written, so a failed capture leaves the vault and the queued
        // temp files exactly as they were.
        let (referenced, unreferenced) =
            partitionAttachmentsByReference(attachments, inText: text)

        let capture = self.capture
        let vaultURL = URL(fileURLWithPath: vault.path)
        let cliVaultName = cliName(for: vault)
        Task { [weak self] in
            let result = await Task.detached {
                Result { try capture.capture(text, toVault: vaultURL, cliVaultName: cliVaultName) }
            }.value
            guard let self else { return }
            switch result {
            case .success(var record):
                DebugLog.log("capture: success → \(record.notePath), created=\(record.createdFile)")
                let copied = self.copyCaptureAttachments(referenced, toVault: vault)
                self.discardTempAttachments(unreferenced)
                record.attachmentPaths = copied.isEmpty ? nil : copied
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
                // The panel cleared the draft when it submitted. Put it and
                // the queued attachments back, so a failed capture doesn't
                // discard what the user wrote — reopening shows it again.
                self.captureDraft = text
                self.captureAttachments = attachments
                self.presentAlert("Capture failed", error.localizedDescription)
            }
        }
    }

    /// Copies a capture's referenced attachments into the vault's attachment
    /// folder, returning where each landed so undo can trash them. Called only
    /// after the note is written. A failure part-way still returns the paths
    /// that did land, so undo can clean up what exists.
    private func copyCaptureAttachments(
        _ attachments: [PluginAttachment], toVault vault: Vault
    ) -> [String] {
        guard !attachments.isEmpty else { return [] }
        let attDir = Courier().attachmentFolder(of: URL(fileURLWithPath: vault.path))
        try? FileManager.default.createDirectory(
            at: attDir, withIntermediateDirectories: true
        )
        let tempPrefix = NSTemporaryDirectory() + "chestnut-plugins/"
        var copied: [String] = []
        for att in attachments {
            let dest = Courier.availableURL(
                for: attDir.appendingPathComponent(att.filename)
            )
            guard Courier.isContained(dest, inVault: vault.path) else {
                presentAlert(
                    "Attachment save failed",
                    "Target path would escape the vault root or write inside .obsidian/."
                )
                return copied
            }
            do {
                let src = URL(fileURLWithPath: att.source).standardizedFileURL
                try FileManager.default.copyItem(at: src, to: dest)
                copied.append(dest.path)
                if att.source.hasPrefix(tempPrefix) {
                    try? FileManager.default.removeItem(at: src)
                }
            } catch {
                presentAlert("Attachment save failed", error.localizedDescription)
                return copied
            }
        }
        return copied
    }

    /// Removes the temp files behind attachments the note didn't refer to.
    private func discardTempAttachments(_ attachments: [PluginAttachment]) {
        guard !attachments.isEmpty else { return }
        DebugLog.log("capture: dropping \(attachments.count) unreferenced attachment(s)")
        let tempPrefix = NSTemporaryDirectory() + "chestnut-plugins/"
        for att in attachments where att.source.hasPrefix(tempPrefix) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: att.source))
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
            if presentUndoFailure("Undo capture failed", error.localizedDescription) {
                discardUndoRecord { try captureJournal.removeLast() }
            }
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
        panel.show(aboveSprite: petWindow.spriteFrame, for: state.noticeDuration)
        notice = panel
        if onClick != nil { hotkeys.setNoticeHotkeyEnabled(true) }
    }

    /// Menu → Edit Configuration…: hand over config.json in whatever the user
    /// edits JSON with. The notice does the work the menu item can't — nothing
    /// here re-reads the file, so an edit is invisible until a relaunch.
    private func openConfigForEditing() {
        // Nothing else guarantees the file exists: createIfMissing runs at
        // launch, but the user can delete it while Chestnut is running.
        config.createIfMissing()
        let url = Config.fileURL
        if NSWorkspace.shared.open(url) {
            showNotice("Opened config.json", "Changes apply after a relaunch")
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showNotice("Revealed config.json", "No app is set to open .json files")
        }
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
            if let tempPath = input.filePath,
               tempPath.hasPrefix(
                   NSTemporaryDirectory() + "chestnut-plugins/") {
                try? FileManager.default.removeItem(atPath: tempPath)
            }
            petWindow?.petScene.setOpenWide(false)
            showNotice("No plugin handles this", type.rawValue + " input")
        case 1:
            runPlugin(
                manifest: matches[0].0, dir: matches[0].1, input: input
            )
        default:
            discardPendingPluginTemp()
            if let tempPath = input.filePath,
               tempPath.hasPrefix(NSTemporaryDirectory() + "chestnut-plugins/") {
                pendingPluginTempPath = tempPath
            }
            presentPalette(
                PluginPalettePanel(plugins: matches) { [weak self] manifest, dir in
                    self?.runPlugin(
                        manifest: manifest, dir: dir, input: input
                    )
                }
            )
        }
    }

    private func discardPendingPluginTemp() {
        guard let path = pendingPluginTempPath else { return }
        pendingPluginTempPath = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    private func runPlugin(
        manifest: PluginManifest, dir: URL, input: PluginRunner.Input
    ) {
        DebugLog.log("plugin run: \(manifest.name) at \(dir.path)")
        // Claim the parked input before the dismiss below fires the palette's
        // onClose, which would delete it as abandoned.
        if pendingPluginTempPath == input.filePath { pendingPluginTempPath = nil }
        palette?.dismiss()
        petWindow?.petScene.setChewing(true)
        let tempPath = input.filePath
        let tempPrefix = NSTemporaryDirectory() + "chestnut-plugins/"
        Task { [weak self] in
            func cleanupTemp() {
                if let tempPath, tempPath.hasPrefix(tempPrefix) {
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
                let captureWithAttachments = result.action == .capture
                    && !(result.attachments ?? []).isEmpty
                self?.petWindow?.petScene.setChewing(false)
                self?.handlePluginResult(result)
                if !captureWithAttachments { cleanupTemp() }
            } catch let error as PluginError {
                cleanupTemp()
                self?.petWindow?.petScene.setChewing(false)
                self?.handlePluginError(error)
            } catch {
                cleanupTemp()
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
            captureAttachments = result.attachments ?? []
            if let open = palette as? CapturePanel {
                open.setDraft(result.content)
            } else {
                toggleCapture()
            }
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
        let filename = result.filename ?? "Untitled.md"
        let content = result.content
        let folder = result.folder
        let attachments = result.attachments ?? []

        func save(to vault: Vault) {
            let vaultURL = URL(fileURLWithPath: vault.path)
            var dir = vaultURL
            if let folder, !folder.isEmpty {
                dir = dir.appendingPathComponent(folder)
            }
            let attDir = Courier().attachmentFolder(of: vaultURL)
            let noteURL = dir.appendingPathComponent(filename)
            let allURLs = [noteURL] + attachments.map {
                attDir.appendingPathComponent($0.filename)
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
                if !attachments.isEmpty {
                    try FileManager.default.createDirectory(
                        at: attDir, withIntermediateDirectories: true
                    )
                }
                let url = Courier.availableURL(for: noteURL)
                try content.write(
                    to: url, atomically: true, encoding: .utf8
                )
                for att in attachments {
                    let src = URL(fileURLWithPath: att.source)
                        .standardizedFileURL
                    let dest = Courier.availableURL(
                        for: attDir.appendingPathComponent(att.filename)
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
        var resolved: Vault? = nil

        if hint == "pinned" {
            resolved = registry.vaults.first { $0.path == state.pinnedVaultPath }
        } else if hint == "last" {
            resolved = registry.vaults.first { $0.path == state.lastCaptureVaultPath }
        } else if let hint, hint != "ask" {
            if let vault = registry.vaults.first(where: { $0.path == hint }) {
                resolved = vault
            } else {
                presentAlert(
                    "Unknown vault",
                    "No vault found at: \(hint)"
                )
                return
            }
        }

        if let resolved {
            save(to: resolved)
        } else {
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
                pinnedPath: state.pinnedVaultPath,
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
        }
    }

    private func handlePluginError(_ error: PluginError) {
        showNotice("Plugin error", error.localizedDescription)
    }

    /// A second instance rewrites the same journals and settings files
    /// wholesale — last writer wins, so the other's undo records vanish.
    /// LaunchServices only dedupes launches of the *same* bundle path; a DMG
    /// copy beside /Applications (or `make run` beside an installed copy)
    /// slips through, so check ourselves before touching anything. A bare
    /// `swift build` binary has no bundle identifier and skips the guard.
    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let pid = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != pid }
    }

    private func presentAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// The alert an undo failure raises, offering a way past the record that
    /// failed. Keeping it is the default and stays the safe answer — the files
    /// are in an unknown state and forgetting them silently would strand them —
    /// but a kept record sits on top of the stack forever, and undo retries it
    /// on every click, so everything older becomes unreachable. Discarding
    /// touches no files; it only stops Chestnut offering this one again.
    /// Returns true when the caller should drop the record.
    /// `changedFiles` is the difference between "undo refused" and "undo got
    /// part of the way". Both keep the record, but only the first can honestly
    /// promise nothing moved, and only the second is pointless to retry.
    private func presentUndoFailure(
        _ title: String, _ reason: String, changedFiles: Bool = false
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = changedFiles
            ? """
            \(reason)
            What could be brought back already has been, so undoing again \
            won't finish the job. Discarding this entry forgets the operation \
            — no files are touched — so the next undo reaches the one before it.
            """
            : """
            \(reason)
            Nothing was changed. Keeping this entry means Chestnut offers the \
            same operation the next time you undo; discarding it forgets the \
            operation — no files are touched — so the next undo reaches the one \
            before it.
            """
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Discard Entry")
        alert.buttons.last?.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Drop a record whose undo failed, once the user has said to. A failure
    /// here is the case the discard exists for, so it can only be reported.
    private func discardUndoRecord(_ remove: () throws -> Void) {
        do {
            try remove()
        } catch {
            presentAlert(
                "Could not discard the entry",
                "\(error.localizedDescription)\nThe undo journal may need a manual check."
            )
        }
    }
}
