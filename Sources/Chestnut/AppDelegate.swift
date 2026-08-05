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
    private let pluginSave = PluginSave()
    private let pluginJournal: Journal<PluginSaveRecord> = .pluginSaves
    private let hotkeys = HotkeyCenter()
    private let pluginRegistry = PluginRegistry()
    /// Every plugin process running right now. The chewing pose and the
    /// Running Plugins submenu are both derived from it.
    private let runRegistry = PluginRunRegistry()
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

        // The pose follows the registry, never an individual run: two
        // overlapping runs used to leave the pet still while the second was
        // still working. See `PluginRunRegistry`.
        runRegistry.onChange = { [weak self] in
            guard let self else { return }
            petWindow?.petScene.setChewing(!runRegistry.isEmpty)
        }
    }

    /// Best-effort, and the word is exact. This runs when the app is *asked* to
    /// quit through AppKit: the menu's Quit row, `NSApp.terminate`, or the
    /// standard quit Apple Event (`osascript -e 'tell application "Chestnut" to
    /// quit'`).
    ///
    /// It does **not** run on a plain `SIGTERM` — measured, not assumed: an
    /// accessory app sent `SIGTERM` dies on the signal's default action with no
    /// delegate callback at all, exactly as it does on `SIGKILL`. So `pkill -x
    /// Chestnut` leaves a running plugin behind, and so does a crash or a force
    /// quit from Activity Monitor. macOS offers no hook that covers those.
    ///
    /// A plugin can therefore outlive Chestnut, and the claim `PLUGINS.md`
    /// makes is "quitting Chestnut normally stops running plugins", never "no
    /// plugin survives Chestnut".
    ///
    /// Nothing waits for the children to die. `SIGTERM` to each group is sent
    /// and the quit continues: a plugin that ignores the signal survives, which
    /// is the same outcome as before this existed, and a `waitpid` that hung
    /// would stall the quit itself — a worse failure than the one it fixes.
    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        pluginRegistry.stop()
        runRegistry.terminateAll()
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
        window.onPluginDrop = { [weak self] type, input, courier in
            self?.handlePluginInput(type: type, input: input, courier: courier)
        }
        // Obsidian's drag omits the path for folders, so there is nothing to
        // deliver and nothing worth guessing at; say which app dropped the
        // information and where the gesture does work.
        window.onPathlessObsidianDrop = { [weak self] in
            self?.showNotice(
                "Obsidian drags folders without their path",
                "Drag the folder from Finder to deliver it"
            )
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
        window.undoPluginSaveRow = { [weak self] in
            self?.pluginJournal.last().map { UndoRow(subtitle: $0.undoMenuSubtitle) }
        }
        window.onUndoPluginSave = { [weak self] in
            self?.undoLastPluginSave()
        }
        window.pendingPluginSaves = { [weak self] in
            self?.pendingPluginSaves.map(\.plugin) ?? []
        }
        window.onResumePluginSave = { [weak self] index in
            self?.resumePluginSave(at: index)
        }
        window.hasCaptureDraft = { [weak self] in
            !(self?.captureDraft.isEmpty ?? true)
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
        window.runningPlugins = { [weak self] in
            self?.runRegistry.runs ?? []
        }
        window.onCancelPluginRun = { [weak self] id in
            self?.runRegistry.cancel(id)
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
            let outcome = try courier.undo(op)
            try journal.removeLast()
            petWindow?.petScene.celebrateDelivery()
            // Every file came home, but a note too large to journal whole came
            // home with the delivery's link rewrites still in it. Rare enough
            // to be a bubble rather than an alert, loud enough not to be silent.
            if !outcome.textNotRestored.isEmpty {
                let names = outcome.textNotRestored
                showNotice(
                    "Links left as they were",
                    names.count == 1
                        ? "\(names[0]) was too large to journal its original text"
                        : "\(names.count) notes were too large to journal their original text"
                )
            }
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

    /// Record what a `save`-mode plugin just wrote, so the Undo row can reach
    /// it. A journal that won't write is logged and dropped rather than raised:
    /// the save itself succeeded and the user has their note, so an alert here
    /// would report a failure they did not experience. The cost is one
    /// unreversible save, which is where every plugin save stood before this.
    private func journalPluginSave(
        plugin: String, vault: Vault, note: URL,
        noteBytes: Int, attachments: [String]
    ) {
        do {
            try pluginJournal.append(PluginSaveRecord(
                date: Date(),
                pluginName: plugin,
                vaultPath: vault.path,
                notePath: note.path,
                noteBytes: noteBytes,
                attachmentPaths: attachments.isEmpty ? nil : attachments
            ))
        } catch {
            DebugLog.log("plugin save journal failed: \(error)")
        }
    }

    private func undoLastPluginSave() {
        guard let record = pluginJournal.last() else { return }
        do {
            try pluginSave.undo(record)
            try pluginJournal.removeLast()
            petWindow?.petScene.celebrateDelivery()
            // The other half of the pair logged in `savePluginOutput`: a note
            // leaving a vault deserves a line as much as one arriving in it.
            // Note that `undo` treats an already-missing note as success and
            // trashes nothing, so this line means the record is gone, not
            // necessarily that a file moved.
            DebugLog.log("plugin save undone: \(record.pluginName) → \(record.notePath)")
        } catch {
            DebugLog.log(
                "plugin save undo failed: \(record.pluginName)"
                + " → \(record.notePath): \(error)"
            )
            if presentUndoFailure(
                "Undo plugin save failed", error.localizedDescription
            ) {
                discardUndoRecord { try pluginJournal.removeLast() }
            }
        }
    }

    /// Success receipt above the pet: what happened and where, click (or the
    /// notice hotkey, registered only while the bubble is up) to follow
    /// through. Failures stay loud NSAlerts — never notices.
    /// - Parameters:
    ///   - duration: Overrides the user's notice duration. Nothing passes this
    ///     today; a parked result once did, and it read as a bubble that would
    ///     not go away.
    ///
    /// A notice is a receipt and nothing else. Missing one — faded, dismissed,
    /// replaced by the next — must never cost anything, so nothing may exist
    /// only inside one. A caller with something to hand over puts it somewhere
    /// reachable first and then announces it here.
    private func showNotice(
        _ title: String, _ subtitle: String,
        duration: TimeInterval? = nil,
        onClick: (() -> Void)? = nil
    ) {
        notice?.dismiss()
        guard let petWindow else { return }
        let hint = onClick == nil ? nil : HotkeySpec.display(config.hotkeys.notice)
        let panel = NoticePanel(title: title, subtitle: subtitle, hotkeyHint: hint, onClick: onClick)
        panel.onDismiss = { [weak self] in
            self?.hotkeys.setNoticeHotkeyEnabled(false)
        }
        panel.show(
            aboveSprite: petWindow.spriteFrame,
            for: duration ?? state.noticeDuration
        )
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
        // An unclassifiable clipboard gets a notice rather than a silent
        // return. This is the only dead end on the paste path with no visible
        // outcome, which makes an empty or stale clipboard indistinguishable
        // from a hotkey that never registered — and the difference between
        // those two is the whole of what the user needs to know. The matching
        // dead end one level down already speaks ("No plugin handles this").
        guard let classified = PluginDispatch.classify(.general) else {
            showNotice("Nothing to paste", "The clipboard is empty or unreadable")
            return
        }
        // No courier candidate: the clipboard image is written to a temp file
        // that gets deleted after the run, so offering delivery would hand the
        // courier a path that disappears underneath it and journal an undo
        // record pointing at nothing.
        handlePluginInput(type: classified.0, input: classified.1, courier: nil)
    }

    /// Dispatch classified input to a plugin, to the courier, or to a choice
    /// between them.
    ///
    /// `courier` delivers this same item and is supplied by the *drop site* —
    /// never inferred from `type` or `input`, since the paste path classifies
    /// identically and must not offer it. When it is non-nil, a single match
    /// still opens the picker: that is the whole point of the change, because
    /// a single match is the common case and it is where a plugin used to take
    /// the item outright. See `DropRouter.Route`.
    private func handlePluginInput(
        type: PluginInputType, input: PluginRunner.Input,
        courier: (() -> Void)?
    ) {
        let matches: [(PluginManifest, URL)]
        if let path = input.filePath {
            let ext = URL(fileURLWithPath: path).pathExtension
            matches = pluginRegistry.pluginsAccepting(type, ext: ext)
        } else {
            matches = pluginRegistry.pluginsAccepting(type)
        }
        DebugLog.log("plugin input: type=\(type.rawValue), \(matches.count) matching plugin(s): \(matches.map(\.0.name)), courier candidate: \(courier != nil)")

        if matches.isEmpty {
            // The router only routes here when a plugin matched, so this is
            // reachable only if the last one was disabled or removed between
            // the drop and now. Deliver rather than refuse: the item was
            // dropped on the pet and something must happen to it.
            if let courier {
                DebugLog.log("plugin input: no plugin left — falling through to the courier")
                deliverInstead(courier)
                return
            }
            if let tempPath = input.filePath,
               tempPath.hasPrefix(
                   NSTemporaryDirectory() + "chestnut-plugins/") {
                try? FileManager.default.removeItem(atPath: tempPath)
            }
            petWindow?.petScene.setOpenWide(false)
            showNotice("No plugin handles this", type.rawValue + " input")
            return
        }

        if matches.count == 1, courier == nil {
            runPlugin(manifest: matches[0].0, dir: matches[0].1, input: input)
            return
        }

        discardPendingPluginTemp()
        if let tempPath = input.filePath,
           tempPath.hasPrefix(NSTemporaryDirectory() + "chestnut-plugins/") {
            pendingPluginTempPath = tempPath
        }
        presentPalette(
            PluginPalettePanel(
                plugins: matches, offerCourier: courier != nil
            ) { [weak self] choice in
                switch choice {
                case .plugin(let manifest, let dir):
                    self?.runPlugin(manifest: manifest, dir: dir, input: input)
                case .courier:
                    guard let courier else { return }
                    self?.deliverInstead(courier)
                }
            }
        )
    }

    /// The picker's courier row. Dismisses first, for the same reason
    /// `runPlugin` does: `beginDelivery` opens the destination palette, and
    /// this panel's `onClose` would otherwise clear `palette` out from under
    /// the one that just opened.
    ///
    /// It deliberately does not run the temp-file cleanup — that path only
    /// ever holds a paste-path temp, and the paste path has no courier row.
    private func deliverInstead(_ deliver: () -> Void) {
        palette?.dismiss()
        deliver()
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
        let tempPath = input.filePath
        let tempPrefix = NSTemporaryDirectory() + "chestnut-plugins/"
        let handle = PluginRunHandle()
        let startedAt = Date()
        // Streamed progress arrives on a background thread. `DispatchQueue.main`
        // rather than a `Task`, because the queue keeps the messages in the
        // order the plugin printed them and hopping through unstructured tasks
        // does not — "3 of 50" after "4 of 50" is worse than no progress.
        let onNotify: @Sendable (String) -> Void = { [weak self] text in
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.showNotice(manifest.name, text)
                }
            }
        }
        Task { [weak self] in
            func cleanupTemp() {
                if let tempPath, tempPath.hasPrefix(tempPrefix) {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
            }
            // Registering turns the chewing pose on and puts the run in the
            // cancel submenu; the `defer` takes both back. One `defer` rather
            // than a call down each exit path — this block has three exits
            // today, each of which used to toggle the pose for itself, and that
            // is exactly the shape that lets a fourth one drift out of sync. A
            // leaked entry chews forever and offers a cancel row that does
            // nothing.
            let runID = self?.runRegistry.register(name: manifest.name, handle: handle)
            defer { if let runID { self?.runRegistry.remove(runID) } }
            do {
                let raw = try await PluginRunner.run(
                    manifest: manifest, pluginDir: dir, input: input,
                    handle: handle, onNotify: onNotify
                )
                DebugLog.log("plugin run: \(manifest.name) exited \(raw.exitCode), stdout=\(raw.stdout.count) bytes, skipped \(raw.skippedLines) line(s), stderr=\(raw.stderr.prefix(200))")
                // Nil means a streaming plugin that reported progress and asked
                // for nothing else. It has already had its say; there is
                // nothing left to apply and nothing to announce.
                guard let result = try PluginRunner.interpret(
                    result: raw, manifest: manifest
                ) else {
                    if let runID { self?.runRegistry.remove(runID) }
                    cleanupTemp()
                    return
                }
                DebugLog.log("plugin result: action=\(result.action.rawValue), content=\(result.content.count) bytes, attachments=\(result.attachments?.count ?? 0)")
                let captureWithAttachments = result.action == .capture
                    && !(result.attachments ?? []).isEmpty
                // Deregistered here as well as in the `defer`, for the
                // animation's sake rather than the registry's: a successful
                // result plays `celebrateDelivery`, and stopping the chew pose
                // afterwards would cut the celebration off with `play`. Removal
                // is idempotent — the `defer` below is still the guarantee, and
                // this call is not one the correctness rests on.
                if let runID { self?.runRegistry.remove(runID) }
                self?.handlePluginResult(
                    result, plugin: manifest.name,
                    elapsed: Date().timeIntervalSince(startedAt)
                )
                if !captureWithAttachments { cleanupTemp() }
            } catch let error as PluginError {
                cleanupTemp()
                self?.handlePluginError(error)
            } catch {
                cleanupTemp()
                self?.handlePluginError(
                    .nonZeroExit(error.localizedDescription))
            }
        }
    }

    /// A run that takes longer than this has outlived the user's attention, and
    /// anything it does that takes over the screen is an interruption rather
    /// than a response. One minute: inside that, the person is still watching
    /// the drop they just made; past it, they have moved on to another app.
    private static let unattendedRunSeconds: TimeInterval = 60

    // A parked result once forced its notice to stay up for a minute, six
    // times the default, because the bubble was the only route to it. Both
    // parked things now have a home the menu can show — a waiting save has a
    // row of its own, a waiting draft badges Capture… — so the bubble is a
    // receipt again and lasts as long as the user asked receipts to last.
    // Sixty seconds of speech balloon over someone else's work was measured
    // and disliked, and nothing needs it now.

    private func handlePluginResult(
        _ result: PluginRunner.InterpretedResult, plugin: String,
        elapsed: TimeInterval
    ) {
        switch result.action {
        case .capture:
            captureDraft = result.content
            captureAttachments = result.attachments ?? []
            if let open = palette as? CapturePanel {
                open.setDraft(result.content)
            } else if elapsed > Self.unattendedRunSeconds {
                // The single most user-hostile thing this feature could do is
                // open a text panel and take the keyboard forty minutes after
                // the drop, while the user is typing in something else. So a
                // late capture parks its draft and says so; the draft is held
                // in `captureDraft` and the next Capture… shows it, exactly as
                // a dismissed capture panel's draft is.
                //
                // Streaming cannot produce a capture mid-run at all — only
                // `notify` is acted on before exit (see `StreamCollector`) —
                // but this is not only a streaming problem: any plugin can now
                // run for hours, and this is the path a capture arrives on
                // whether it streamed or not.
                // The draft was assigned to `captureDraft` above, before this
                // branch, and the Capture… row badges itself while one is
                // waiting. So this notice is a shortcut and nothing more:
                // missing it costs the shortcut, never the draft.
                showNotice(
                    "\(plugin) has a draft ready",
                    "Click to open it in Capture"
                ) { [weak self] in
                    self?.toggleCapture()
                }
            } else {
                toggleCapture()
            }
        case .save:
            savePluginOutput(result, plugin: plugin, elapsed: elapsed)
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

    private func savePluginOutput(
        _ result: PluginRunner.InterpretedResult, plugin pluginName: String,
        elapsed: TimeInterval
    ) {
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
            // Every path this function creates or writes gets checked, not
            // just the files. `dir` comes straight from the envelope's
            // `folder`, and checking only `noteURL` left a gap: an escaping
            // `folder` paired with a `filename` that walked back in cancelled
            // out, so the note landed correctly inside the vault while
            // createDirectory made the escaped folder anyway.
            let dirs = attachments.isEmpty ? [dir] : [dir, attDir]
            let files = [noteURL] + attachments.map {
                attDir.appendingPathComponent($0.filename)
            }
            let escapes = dirs.contains {
                !Courier.isContainedDirectory($0, inVault: vault.path)
            } || files.contains {
                !Courier.isContained($0, inVault: vault.path)
            }
            if escapes {
                DebugLog.log(
                    "plugin save refused: \(pluginName) → \(noteURL.path)"
                    + " escapes \(vault.path)"
                )
                presentAlert(
                    "Plugin save failed",
                    "Target path would escape the vault root or write inside .obsidian/."
                )
                return
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
                // Collected as each copy lands, not derived up front from
                // `attachments`: `availableURL` picks the suffixed name only
                // once it sees what is already there, and a copy that throws
                // half way through must leave the journal naming the files
                // that exist rather than the ones that were planned.
                var attachmentPaths: [String] = []
                defer {
                    journalPluginSave(
                        plugin: pluginName, vault: vault, note: url,
                        noteBytes: content.utf8.count,
                        attachments: attachmentPaths
                    )
                    // Logged next to the journal write and for the same
                    // reason the courier logs every from → to pair: this is
                    // the moment a file appears in a vault. Without it the
                    // log falls silent exactly there, and finding where a
                    // note went meant reading the journal — which records
                    // only saves that succeeded, and exists to be popped.
                    DebugLog.log(
                        "plugin save: \(pluginName) → \(url.path)"
                        + ", \(content.utf8.count) bytes"
                        + ", \(attachmentPaths.count) attachment(s)"
                    )
                }
                for att in attachments {
                    let src = URL(fileURLWithPath: att.source)
                        .standardizedFileURL
                    let dest = Courier.availableURL(
                        for: attDir.appendingPathComponent(att.filename)
                    )
                    try FileManager.default.copyItem(at: src, to: dest)
                    attachmentPaths.append(dest.path)
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
                DebugLog.log(
                    "plugin save failed: \(pluginName) → \(vault.path): \(error)"
                )
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
            return
        }

        let vaults = pinnedFirst(registry.vaults)
        guard !vaults.isEmpty else {
            presentAlert(
                "Nowhere to save",
                "No vaults found in Obsidian's vault list."
            )
            return
        }

        // The picker the user opened and then walked away from: they saw it,
        // they dismissed it, and the output goes somewhere they can reach
        // rather than nowhere. This is the original fallback and it predates
        // everything else here.
        func copyToClipboard() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            showNotice(
                "Copied to clipboard",
                "Plugin output saved to clipboard"
            )
        }

        func askForVault() {
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
            // `afterDismiss`, not `onClose`: a second plugin finishing while
            // this picker is open calls `presentPalette`, which clears
            // `onClose` before dismissing. Chaining onto `onClose` put this
            // fallback exactly where that line wipes it, so the first
            // plugin's output was not saved, not copied, and not reported.
            panel.afterDismiss = {
                guard !saved else { return }
                copyToClipboard()
            }
            presentPalette(panel)
        }

        guard elapsed > Self.unattendedRunSeconds else {
            askForVault()
            return
        }
        // A picker is a panel that takes the keyboard, so it is subject to the
        // same rule as a late capture (see `handlePluginResult`) — and the
        // reason is not only theoretical. Measured during hand testing: the
        // picker opened underneath a Return the user was pressing in another
        // app, that keystroke selected the highlighted vault, and a note was
        // written to a vault they never chose. Nothing about the keystroke was
        // addressed to Chestnut.
        //
        // A save that names its vault is untouched by this: it resolved above
        // and needs no UI at all.
        //
        // The output is put somewhere before the notice is shown, never inside
        // it. An earlier version kept the waiting save alive only as a closure
        // held by the bubble, which made every way a bubble can end — faded,
        // dismissed, replaced by the next one — a way to lose a plugin's work,
        // and the handling of those cases is what turned this function into a
        // thicket and crashed the app once. The notice below is now only an
        // announcement: it can be missed with no consequence, because the menu
        // row holds the offer for as long as it stands.
        let pending = PendingPluginSave(result: result, plugin: pluginName)
        pendingPluginSaves.append(pending)
        DebugLog.log("plugin save parked: \(pluginName) is waiting for a vault")
        showNotice(
            "\(pluginName) is waiting to save",
            "Click to choose a vault"
        ) { [weak self] in
            self?.resumePluginSave(id: pending.id)
        }
    }

    /// A plugin's finished output with nowhere to go yet, held until the user
    /// says where. One entry per waiting plugin and one menu row each: a
    /// single slot would have let a second late plugin overwrite the first,
    /// which is the same loss this whole design exists to prevent.
    private struct PendingPluginSave {
        let id = UUID()
        let result: PluginRunner.InterpretedResult
        let plugin: String
    }

    private var pendingPluginSaves: [PendingPluginSave] = []

    /// Menu → Save X's Output…. The row's position is its index, which is safe
    /// only because the menu is rebuilt on every open.
    private func resumePluginSave(at index: Int) {
        guard pendingPluginSaves.indices.contains(index) else { return }
        resumePluginSave(id: pendingPluginSaves[index].id)
    }

    /// Resuming replays the save with an elapsed time of zero, which is true of
    /// *this* moment however long the plugin itself took: the user just asked
    /// for it, so a picker is now a response rather than an interruption.
    ///
    /// By identity and not by position, because a notice outlives the list it
    /// refers to. Its bubble can still be on screen when a second plugin parks
    /// behind it, and resuming "the first one" would then run whichever save
    /// the user was not looking at.
    private func resumePluginSave(id: UUID) {
        guard let index = pendingPluginSaves.firstIndex(where: { $0.id == id })
        else { return }
        let pending = pendingPluginSaves.remove(at: index)
        savePluginOutput(pending.result, plugin: pending.plugin, elapsed: 0)
    }

    /// A cancellation is not an error — the user asked for it — so it gets its
    /// own title rather than being reported under "Plugin error" like a failure
    /// they need to look into.
    private func handlePluginError(_ error: PluginError) {
        if case .cancelled = error {
            showNotice("Plugin stopped", "You cancelled the run.")
            return
        }
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
