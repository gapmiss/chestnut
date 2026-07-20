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
        UserDefaults.standard.set(300, forKey: "NSInitialToolTipDelay")
        if let custom = config.customThemes {
            SpriteTheme.registerCustomThemes(custom)
        }
        if SpriteTheme.theme(id: config.petTheme).id != config.petTheme {
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
        hotkeys.start(config: config.hotkeys)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
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
        window.onFilesDropped = { [weak self] urls, copy in
            self?.beginDelivery(of: urls, copy: copy)
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
        palette?.dismiss()  // close first so the gulp isn't stomped by the pose reset
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
            petWindow?.petScene.celebrateDelivery()
            controller.noteInteraction()
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
                    // Several attachments land in one folder — reveal that.
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
        config.lastCaptureVaultPath = vault.path
        config.save()
        // The CLI path blocks on the live Obsidian app (hard 3s timeouts,
        // twice) — run it off the main actor so the pet, panels, and hotkeys
        // stay responsive, then hop back for the journal and feedback.
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
        panel.show(aboveSprite: petWindow.spriteFrame)
        notice = panel
        if onClick != nil { hotkeys.setNoticeHotkeyEnabled(true) }
    }

    private func presentAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
