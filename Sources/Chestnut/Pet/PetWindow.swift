import AppKit
import ServiceManagement
import SpriteKit

/// Transparent, borderless, always-on-top panel that hosts the pet scene.
/// Handles drag-to-move, the right-click menu, and per-pixel click-through.
@MainActor
final class PetWindow: NSPanel {
    let controller: PetController
    let petScene: PetScene

    /// Called when position (or anything else persisted) changes.
    var onStateChange: ((AppState) -> Void)?
    /// Called when the user picks a new size; the delegate rebuilds the window.
    var onSelectSize: ((AppState.PetSize) -> Void)?
    /// Called when the user picks a theme; the delegate rebuilds the window
    /// (same path as a size change — no re-texturing of a live scene).
    var onSelectTheme: ((String) -> Void)?
    /// Called on click / menu → Vaults…; the delegate toggles the Vault Hopper.
    var onToggleHopper: (() -> Void)?
    /// Files dropped on the pet; second argument is the effective copy flag
    /// (persisted default already XOR-ed with ⌥).
    var onFilesDropped: (([URL], Bool) -> Void)?
    /// Non-.md content dropped on the pet, classified for plugin dispatch.
    var onPluginDrop: ((PluginInputType, PluginRunner.Input) -> Void)?
    /// Resolve a vault name (from an obsidian:// URL) to a vault path.
    var resolveVaultByName: ((String) -> String?)?
    var hasPluginForFileExt: ((PluginInputType, String) -> Bool)?
    var hasPluginForType: ((PluginInputType) -> Bool)?
    var onUndoDelivery: (() -> Void)?
    /// The Undo Last Delivery row, resolved from the record it would reverse;
    /// nil when there's nothing journaled, which is also what disables it.
    var undoDeliveryRow: (() -> UndoRow?)?
    /// Quick Capture: menu → Capture… (the global hotkey lands in the delegate).
    var onCapture: (() -> Void)?
    var onUndoCapture: (() -> Void)?
    var undoCaptureRow: (() -> UndoRow?)?
    var installedPlugins: (() -> [PluginManifest])?
    var isPluginEnabled: ((String) -> Bool)?
    var togglePlugin: ((String) -> Void)?
    var onOpenPluginsFolder: (() -> Void)?
    /// Menu → Edit Configuration…; the delegate opens config.json.
    var onEditConfiguration: (() -> Void)?
    /// True while the right-click menu is on screen. The delegate releases the
    /// `menu` hotkey for that window; see `HotkeyCenter.setMenuHotkeyEnabled`.
    var onMenuTrackingChange: ((Bool) -> Void)?

    private var state: AppState
    /// Hand-edited settings: read-only here, never written back.
    private let config: Config

    /// Whether each Undo row had a record when the menu was last built; see
    /// `validateMenuItem`.
    private var undoDeliveryAvailable = false
    private var undoCaptureAvailable = false

    /// See `PetGeometry.Margin` — kept as an alias so call sites read the same.
    typealias Margin = PetGeometry.Margin

    // The origin maths lives in `PetGeometry`, which takes screen rects rather
    // than `NSScreen` so `make check` can reach it; this file is AppKit and
    // can't join the check target. These wrappers supply the current displays.

    private static var mainVisibleFrame: NSRect {
        NSScreen.main?.visibleFrame ?? PetGeometry.fallbackVisibleFrame
    }

    private static var currentScreens: [PetScreen] {
        NSScreen.screens.map { PetScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// System Settings ▸ Accessibility ▸ Display ▸ Reduce Motion.
    private static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func contentSize(for size: AppState.PetSize) -> NSSize {
        PetGeometry.contentSize(for: size)
    }

    static func defaultOrigin(for contentSize: NSSize) -> NSPoint {
        PetGeometry.defaultOrigin(for: contentSize, onVisible: mainVisibleFrame)
    }

    /// The sprite's current on-screen rect — the anchor for the notice
    /// bubble's tail (the window frame itself has invisible headroom).
    var spriteFrame: NSRect {
        Self.petRect(inWindowFrame: frame, scale: state.size.pixelScale)
    }

    /// The sprite's rect within a window frame (frame minus the margins).
    static func petRect(inWindowFrame frame: NSRect, scale: CGFloat) -> NSRect {
        PetGeometry.petRect(inWindowFrame: frame, scale: scale)
    }

    /// Clamp a window origin so the whole sprite sits inside `screen`'s
    /// visible frame (below the menu bar, above the Dock). A nil screen means
    /// there is nothing to clamp against, so the origin stands.
    static func clampedOrigin(
        _ origin: NSPoint, for petSize: AppState.PetSize, on screen: NSScreen?
    ) -> NSPoint {
        guard let visible = screen?.visibleFrame else { return origin }
        return PetGeometry.clampedOrigin(origin, for: petSize, onVisible: visible)
    }

    /// A saved position is only trusted if part of the sprite is on a screen —
    /// displays come and go, and constrainFrameRect no longer rescues us.
    /// Trusted positions are still clamped into the visible area.
    static func validatedOrigin(_ saved: NSPoint?, for petSize: AppState.PetSize) -> NSPoint {
        PetGeometry.validatedOrigin(
            saved, for: petSize, screens: currentScreens, mainVisible: mainVisibleFrame
        )
    }

    init(state: AppState, config: Config, controller: PetController) {
        self.state = state
        self.config = config
        self.controller = controller

        let size = Self.contentSize(for: state.size)
        let origin = Self.validatedOrigin(state.position, for: state.size)
        petScene = PetScene(
            size: size,
            pixelScale: state.size.pixelScale,
            palette: SpriteTheme.resolvedPalette(
                themeID: state.petTheme, overrides: config.petPalette
            )
        )

        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        alphaValue = state.opacity
        level = .floating
        collectionBehavior = Self.collectionBehavior(showInFullScreen: state.showInFullScreen)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let view = PetView(frame: NSRect(origin: .zero, size: size))
        view.allowsTransparency = true
        view.presentScene(petScene)
        view.registerForDraggedTypes([.fileURL, .string, .URL, .tiff, .png])
        contentView = view

        acceptsMouseMovedEvents = true
        startClickThroughTracking()
        applyMotionSetting()

        // Reduce Motion can be switched on while the app runs, and the whole
        // point of the setting is that it takes effect without hunting down
        // each app. NSWorkspace posts this on its own centre, not the default.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        // Displays come and go while the app runs, not just between launches.
        // `constrainFrameRect` is overridden to a no-op, so nothing else pulls
        // a stranded pet back onto a screen — and a pet with no screen takes
        // the right-click menu with it, which is the only route to Reset
        // Position or Quit besides the menu hotkey.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        applyMotionSetting()
    }

    /// Push the effective stillness down to the scene. Chestnut's setting and
    /// the system's are combined in `AppState.motionFrozen`, which documents
    /// why the system one wins.
    private func applyMotionSetting() {
        petScene.setMotionFrozen(AppState.motionFrozen(
            app: state.reduceMotion, system: Self.systemReduceMotion
        ))
    }

    /// Re-run the launch-time validation against the new display list.
    ///
    /// Deliberately does *not* persist the rescued origin. `state.position` is
    /// the position the user chose, and a display they unplug now is one they
    /// may plug back in later: keeping their coordinates means the pet returns
    /// there on the next launch while docked, and gets rescued again while
    /// undocked. Overwriting it would trade that for a permanent move to the
    /// default corner. A drag still saves, as it always did.
    @objc private func screenParametersChanged() {
        let rescued = Self.validatedOrigin(frame.origin, for: state.size)
        guard rescued != frame.origin else { return }
        setFrameOrigin(rescued)
    }

    /// A floating .canJoinAllSpaces window shows over full-screen apps even
    /// without .fullScreenAuxiliary; .fullScreenNone is what actually keeps
    /// it off full-screen spaces (verified empirically on macOS 15). The
    /// window reappears on its own when a normal space becomes active.
    static func collectionBehavior(showInFullScreen: Bool) -> NSWindow.CollectionBehavior {
        showInFullScreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .fullScreenNone]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }


    /// macOS pins a window's top edge below the menu bar; with our transparent
    /// top margin that held the visible pet ~56pt short of the screen top
    /// (while the slim bottom margin let it nearly touch the bottom edge).
    /// Let the pet sit anywhere — validatedOrigin and Reset Position cover
    /// off-screen recovery.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: - User actions

    /// Drag: keep the sprite inside the visible frame of the screen under the
    /// cursor, so it can't hide under the menu bar but can cross displays.
    func dragMove(to origin: NSPoint) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
        setFrameOrigin(Self.clampedOrigin(origin, for: state.size, on: screen))
    }

    func dragEnded() {
        state.position = frame.origin
        onStateChange?(state)
        controller.noteInteraction()
    }

    func petClicked() {
        petScene.handleClick()
        controller.noteInteraction()
        onToggleHopper?()
    }

    // MARK: - Note Courier (drop target)

    /// Effective operation for a file drag: the persisted default, flipped by ⌥.
    var courierDragOperation: NSDragOperation {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        return state.courierCopyByDefault != optionHeld ? .copy : .move
    }

    func filesDropped(_ urls: [URL]) {
        controller.noteInteraction()
        onFilesDropped?(urls, courierDragOperation == .copy)
    }

    /// Actions first, ordered by how often they're used; settings collapse into
    /// one submenu. Size and Theme stay top-level on purpose — they're the
    /// pet's identity and the most rewarding thing to find early.
    func showMenu(with event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: view)
    }

    /// Keyboard route to the same menu (the `menu` hotkey). Two things this
    /// needs that the click path gets for free: a location, since there's no
    /// event to take one from, and app activation — menu tracking pulls key
    /// events from *our* queue, and while Chestnut is a background accessory
    /// app they go to whatever is frontmost instead, so the menu would appear
    /// but not respond to arrow keys. macOS constrains the menu onto a screen,
    /// so an off-screen sprite still yields a usable menu.
    func showMenuFromHotkey() {
        NSApp.activate(ignoringOtherApps: true)
        let sprite = spriteFrame
        let menu = buildMenu()
        let screen = NSScreen.screens.first { $0.frame.intersects(sprite) } ?? NSScreen.main
        menu.popUp(
            positioning: nil,
            at: PetGeometry.menuOrigin(for: menu.size, at: sprite, in: screen?.visibleFrame),
            in: nil
        )
    }

    private func buildMenu() -> NSMenu {
        // Visual changes here should be mirrored in the website's re-creation
        // (docs/chestnut.js, renderMenu).
        let menu = NSMenu()
        // Only the root menu gets the delegate: submenus opening and closing
        // aren't the menu itself opening and closing.
        menu.delegate = self

        menu.addItem(menuItem("Vaults…", #selector(toggleHopper), hotkey: config.hotkeys.hopper))
        menu.addItem(menuItem("Capture…", #selector(beginCapture), hotkey: config.hotkeys.capture))

        menu.addItem(.separator())
        let delivery = undoDeliveryRow?()
        let capture = undoCaptureRow?()
        undoDeliveryAvailable = delivery != nil
        undoCaptureAvailable = capture != nil
        menu.addItem(undoMenuItem("Undo Last Delivery", #selector(undoDelivery), delivery))
        menu.addItem(undoMenuItem("Undo Last Capture", #selector(undoCapture), capture))

        menu.addItem(.separator())
        menu.addItem(sizeMenuItem())
        menu.addItem(themeMenuItem())
        menu.addItem(settingsMenuItem())
        menu.addItem(pluginsMenuItem())

        menu.addItem(.separator())
        menu.addItem(updatesMenuItem())
        let supportItem = menuItem("Support Chestnut", #selector(openSupport))
        supportItem.image = NSImage(
            systemSymbolName: "heart", accessibilityDescription: "GitHub Sponsors"
        )
        supportItem.badge = NSMenuItemBadge(string: Self.opensInBrowser)
        menu.addItem(supportItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Chestnut", #selector(quitApp)))

        return menu
    }

    /// A plain action row targeting this window, optionally showing the key
    /// equivalent of a configured hotkey.
    private func menuItem(
        _ title: String, _ action: Selector, hotkey: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        // One grammar: the same parse that backs the Carbon registration
        // (HotkeySpec) supplies the display, so they can't drift.
        if let hotkey, let (key, mods) = HotkeySpec(hotkey)?.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
        return item
    }

    /// An Undo row. The title is fixed; the record it would reverse names
    /// itself on the second line, because undo pops one record per click and
    /// after the first click a bare title refers to a different, older
    /// operation with nothing on screen to say so. Subtitle rather than title
    /// so a long note name can't set the width of every row in the menu —
    /// see `UndoRow`. A record from before names were kept draws plain, as
    /// does every row on 14.0–14.3, where `subtitle` doesn't exist yet: the
    /// row still works, it just goes back to being unnamed.
    private func undoMenuItem(
        _ title: String, _ action: Selector, _ row: UndoRow?
    ) -> NSMenuItem {
        let item = menuItem(title, action)
        if #available(macOS 14.4, *) { item.subtitle = row?.subtitle }
        return item
    }

    private static func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func sizeMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for size in AppState.PetSize.allCases {
            let item = menuItem(size.title, #selector(selectSize(_:)))
            item.representedObject = size.rawValue
            item.state = size == state.size ? .on : .off
            submenu.addItem(item)
        }
        return Self.submenuItem("Size", submenu)
    }

    private func themeMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for theme in SpriteTheme.all {
            let item = menuItem(theme.title, #selector(selectTheme(_:)))
            item.representedObject = theme.id
            item.state = theme.id == state.petTheme ? .on : .off
            submenu.addItem(item)
        }
        return Self.submenuItem("Theme", submenu)
    }

    /// Everything you set once: two value pickers, three toggles, two escape
    /// hatches.
    ///
    /// Opacity and Notice Bubble are the only rows that open a third level, and
    /// they are why the "never a third level" rule now has an exception. They
    /// were sliders, which are `NSMenuItem.view`s, and AppKit skips view items
    /// in a menu's key loop — so neither value could be changed without a
    /// mouse. For opacity that could strand you: faded to its floor, the sprite
    /// is nearly invisible, and the only control that restored it was a slider
    /// you had to find and drag on a pet you could no longer see. Discrete
    /// items are ordinary items: arrow keys reach them, Return picks one, the
    /// checkmark is the current value, and there is one control per value
    /// rather than a slider shadowed by a keyboard stand-in. The cost is the
    /// fine control the slider had, spent deliberately.
    private func settingsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()

        submenu.addItem(presetMenuItem(
            title: "Opacity",
            hint: "How solid Chestnut looks",
            presets: AppState.opacityPresets,
            current: state.opacity,
            action: #selector(selectOpacity(_:)),
            label: Self.percentLabel
        ))
        submenu.addItem(presetMenuItem(
            title: "Notice Bubble",
            hint: "How long a notice bubble stays on screen",
            presets: AppState.noticeDurationPresets,
            current: state.noticeDuration,
            action: #selector(selectNoticeDuration(_:)),
            label: Self.secondsLabel
        ))

        submenu.addItem(.separator())
        // Sits with the pet's own presentation, above the courier and window
        // toggles. Named after the system setting because that's the term the
        // people who want it will look for; the subtitle is what stops the row
        // being read as a *mirror* of that switch, which ticking it must never
        // write. Disabled while the system asks, since this can only ever add
        // stillness — `AppState.motionFrozen` says why. On 14.0–14.3 there's no
        // subtitle API and the row draws bare but still dimmed.
        let motionItem = menuItem("Reduce Motion", #selector(toggleReduceMotion))
        let systemAsks = Self.systemReduceMotion
        motionItem.state = AppState.motionFrozen(
            app: state.reduceMotion, system: systemAsks
        ) ? .on : .off
        if systemAsks, #available(macOS 14.4, *) {
            motionItem.subtitle = "Set in System Settings"
        }
        submenu.addItem(motionItem)
        let copyItem = menuItem("Copy on Drop", #selector(toggleCopyDefault))
        copyItem.state = state.courierCopyByDefault ? .on : .off
        submenu.addItem(copyItem)
        let fullScreenItem = menuItem("Show in Full Screen", #selector(toggleShowInFullScreen))
        fullScreenItem.state = state.showInFullScreen ? .on : .off
        submenu.addItem(fullScreenItem)
        let loginItem = menuItem("Launch at Login", #selector(toggleLaunchAtLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        submenu.addItem(loginItem)

        submenu.addItem(.separator())
        submenu.addItem(menuItem("Reset Position", #selector(resetPosition)))
        submenu.addItem(menuItem("Edit Configuration…", #selector(editConfiguration)))

        return Self.submenuItem("Settings", submenu)
    }

    private func pluginsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let plugins = installedPlugins?() ?? []
        if plugins.isEmpty {
            let noneItem = NSMenuItem(
                title: "No plugins installed", action: nil, keyEquivalent: ""
            )
            noneItem.isEnabled = false
            submenu.addItem(noneItem)
        } else {
            for plugin in plugins.sorted(by: { $0.name < $1.name }) {
                let item = menuItem(plugin.name, #selector(togglePluginAction(_:)))
                item.representedObject = plugin.name
                let enabled = isPluginEnabled?(plugin.name) ?? true
                item.state = enabled ? .on : .off
                if !plugin.description.isEmpty {
                    let title = NSMutableAttributedString(
                        string: plugin.name,
                        attributes: [.font: NSFont.menuFont(ofSize: 0)]
                    )
                    title.append(NSAttributedString(
                        string: "\n\(plugin.description)",
                        attributes: [
                            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ]
                    ))
                    item.attributedTitle = title
                }
                submenu.addItem(item)
            }
        }
        submenu.addItem(.separator())
        submenu.addItem(menuItem("Open Plugins Folder", #selector(openPluginsFolder)))
        return Self.submenuItem("Plugins", submenu)
    }

    /// The version rides along as a badge rather than a dead disabled row: it
    /// stays quotable in a bug report without spending a line. NSMenuItem
    /// allows only one badge, so the opens-in-browser ↗ joins the string.
    private func updatesMenuItem() -> NSMenuItem {
        let item = menuItem("Check for Updates…", #selector(openReleases))
        item.badge = NSMenuItemBadge(string: "\(AppInfo.version) \(Self.opensInBrowser)")
        return item
    }

    /// One row shape for both value pickers: a parent naming the setting, and a
    /// submenu of preset choices with the current one checked. The parent
    /// carries the value as a badge so the setting can be read without opening
    /// it, and `hint` becomes its tooltip — "Opacity" is self-evident where a
    /// duration isn't.
    ///
    /// The checkmark is an exact match, so a value persisted between stops by
    /// an older build shows none. That's deliberate: checking the nearest stop
    /// would claim a value the app isn't using. Picking any preset resolves it.
    private func presetMenuItem(
        title: String,
        hint: String,
        presets: [Double],
        current: Double,
        action: Selector,
        label: (Double) -> String
    ) -> NSMenuItem {
        let submenu = NSMenu()
        for preset in presets {
            let item = menuItem(label(preset), action)
            item.representedObject = preset
            item.state = AppState.isPreset(preset, matching: current) ? .on : .off
            submenu.addItem(item)
        }
        let parent = Self.submenuItem(title, submenu)
        parent.badge = NSMenuItemBadge(string: label(current))
        parent.toolTip = hint
        return parent
    }

    /// Whole seconds only: a bubble that lingers 7.4s isn't a distinct choice
    /// from one that lingers 7.
    private static func secondsLabel(_ seconds: Double) -> String {
        "\(Int(seconds.rounded()))s"
    }

    private static func percentLabel(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Both pickers persist immediately. The sliders they replaced had to wait
    /// for mouse-up to avoid writing on every drag tick; a discrete choice is a
    /// single event, so there's nothing to defer.
    @objc private func selectOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        alphaValue = value
        state.opacity = value
        onStateChange?(state)
    }

    @objc private func selectNoticeDuration(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        state.noticeDuration = value
        onStateChange?(state)
    }

    @objc private func editConfiguration() {
        onEditConfiguration?()
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = AppState.PetSize(rawValue: raw) else { return }
        onSelectSize?(size)
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectTheme?(id)
    }

    @objc private func resetPosition() {
        state.position = nil
        setFrameOrigin(Self.defaultOrigin(for: frame.size))
        onStateChange?(state)
    }

    @objc private func toggleHopper() { onToggleHopper?() }

    @objc private func beginCapture() { onCapture?() }

    @objc private func undoDelivery() { onUndoDelivery?() }

    @objc private func undoCapture() { onUndoCapture?() }

    @objc private func toggleReduceMotion() {
        state.reduceMotion.toggle()
        applyMotionSetting()
        onStateChange?(state)
    }

    @objc private func toggleCopyDefault() {
        state.courierCopyByDefault.toggle()
        onStateChange?(state)
    }

    @objc private func toggleShowInFullScreen() {
        state.showInFullScreen.toggle()
        collectionBehavior = Self.collectionBehavior(showInFullScreen: state.showInFullScreen)
        // The window server doesn't re-evaluate space membership on a live
        // collectionBehavior change: toggled off while on a full-screen space,
        // the window would stay there in a broken state (visible, but its
        // context menu can no longer open). Re-ordering forces the re-eval.
        orderOut(nil)
        orderFrontRegardless()
        onStateChange?(state)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Launch at Login toggle failed: %@", error.localizedDescription)
        }
    }

    /// Trailing ↗ marking items that leave the app for the browser. Carried in a
    /// badge (macOS 14+) rather than an attributed title: the system renders it
    /// right-aligned in secondary color and re-tints it correctly on highlight.
    private static let opensInBrowser = "↗"

    @objc private func togglePluginAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        togglePlugin?(name)
    }

    @objc private func openPluginsFolder() { onOpenPluginsFolder?() }

    @objc private func openReleases() { NSWorkspace.shared.open(AppInfo.releasesURL) }

    @objc private func openSupport() { NSWorkspace.shared.open(AppInfo.supportURL) }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Per-pixel click-through

    // hitTest(nil) alone only stops our views from handling a click — the window
    // server still routes it to this window, swallowing it. True pass-through to
    // the app behind requires ignoresMouseEvents, toggled as the cursor moves:
    // over a visible sprite pixel the window is clickable, elsewhere it is
    // transparent to clicks. Event-driven (mouse-moved monitors), no polling.
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var cursorOverPet = false

    /// The window is rebuilt on size change; without this, each rebuild would
    /// leave the old window's monitors installed (one dead pair per resize).
    override func close() {
        if let monitor = globalMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        // Same reason as the monitors above: a theme or size change rebuilds
        // the window, and a stale observer would move a dead one.
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        super.close()
    }

    private func startClickThroughTracking() {
        // Global monitor sees moves while we ignore events (cursor over the
        // margin); local monitor sees moves while we are clickable.
        // .leftMouseDragged matters for the courier: a Finder drag emits drags,
        // not moves, and the window must stop ignoring mouse events before the
        // drag reaches the sprite or draggingEntered will never fire.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.updateClickThrough() }
            return event
        }
        updateClickThrough()
    }

    private func updateClickThrough() {
        guard let view = contentView as? PetView else { return }
        let screenPoint = NSEvent.mouseLocation
        guard frame.contains(screenPoint) else {
            setCursorOverPet(false)
            return
        }
        let windowPoint = convertPoint(fromScreen: screenPoint)
        let viewPoint = view.convert(windowPoint, from: nil)
        let scenePoint = view.convert(viewPoint, to: petScene)
        setCursorOverPet(petScene.petContainsOpaquePixel(at: scenePoint))
    }

    private func setCursorOverPet(_ over: Bool) {
        if ignoresMouseEvents != !over {
            ignoresMouseEvents = !over
        }
        if cursorOverPet != over {
            cursorOverPet = over
            controller.noteHover(over)
        }
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Answered from what buildMenu resolved a moment ago, rather than
        // reading the journal a second time for every right-click.
        if menuItem.action == #selector(undoDelivery) { return undoDeliveryAvailable }
        if menuItem.action == #selector(undoCapture) { return undoCaptureAvailable }
        // The system already stilled the pet; the row has nothing left to give
        // and must not appear to offer a way back.
        if menuItem.action == #selector(toggleReduceMotion) { return !Self.systemReduceMotion }
        return true
    }
}

/// Reports menu tracking so the `menu` hotkey can be released for its duration
/// — see `HotkeyCenter.setMenuHotkeyEnabled` for why holding it is worse than
/// useless. Both entry points route through `buildMenu`, so a right-click is
/// covered as well as the hotkey.
extension PetWindow: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        onMenuTrackingChange?(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        onMenuTrackingChange?(false)
    }
}

/// SKView whose hitTest only claims clicks that land on a visible sprite pixel,
/// and which turns drags into window moves and clicks into pet gestures.
@MainActor
final class PetView: SKView {
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var didDrag = false

    private var petWindow: PetWindow? { window as? PetWindow }
    private var petScene: PetScene? { scene as? PetScene }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let petScene else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        let scenePoint = convert(local, to: petScene)
        return petScene.petContainsOpaquePixel(at: scenePoint) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse, let origin = dragStartOrigin else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.x
        let dy = mouse.y - start.y
        if !didDrag, hypot(dx, dy) < 3 { return }
        didDrag = true
        petWindow?.dragMove(to: NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            petWindow?.dragEnded()
        } else {
            petWindow?.petClicked()
        }
        dragStartMouse = nil
        dragStartOrigin = nil
        didDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        petWindow?.showMenu(with: event, in: self)
    }

    // MARK: - Note Courier drop target
    // hitTest already scopes drags to opaque sprite pixels, so these fire
    // only when files hover the chest itself.

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.fileURLs()
    }

    private func obsidianLinks(from sender: NSDraggingInfo) -> [ObsidianOpenLink] {
        guard let raw = sender.draggingPasteboard.string(forType: .URL) else { return [] }
        return ObsidianOpenLink.links(in: raw)
    }

    /// The files behind a drag out of Obsidian's file explorer, skipping any
    /// link that no longer resolves.
    ///
    /// Skipping rather than refusing the whole drop: a multi-select comes from
    /// one vault, so the failures that would make the *set* untrustworthy — an
    /// ambiguous vault name, a vault missing from the registry — fail every
    /// link alike and leave nothing to deliver. What fails singly is a file
    /// renamed or deleted in Obsidian since the drag began, and stranding its
    /// siblings for that would repeat the mistake `Courier.undo` was fixed for.
    /// `resolve` logs each one it drops.
    private func obsidianFileURLs(from sender: NSDraggingInfo) -> [URL] {
        obsidianLinks(from: sender).compactMap(resolve)
    }

    private func resolve(_ link: ObsidianOpenLink) -> URL? {
        DebugLog.log("obsidian:// URL — vault=\(link.vaultName) file=\(link.filePath)")
        guard let vault = petWindow?.resolveVaultByName?(link.vaultName) else {
            DebugLog.log("obsidian:// — vault \"\(link.vaultName)\" not found in registry")
            return nil
        }
        let fullURL = URL(fileURLWithPath:
            (vault as NSString).appendingPathComponent(link.filePath))
        guard Courier.isContained(fullURL, inVault: vault) else {
            DebugLog.log("obsidian:// — file path escapes vault root")
            return nil
        }
        if FileManager.default.fileExists(atPath: fullURL.path) {
            DebugLog.log("obsidian:// — resolved to \(fullURL.path)")
            return fullURL
        }
        if !fullURL.path.hasSuffix(".md") {
            let withMD = URL(fileURLWithPath: fullURL.path + ".md")
            if FileManager.default.fileExists(atPath: withMD.path) {
                DebugLog.log("obsidian:// — resolved to \(withMD.path)")
                return withMD
            }
        }
        DebugLog.log("obsidian:// — resolved path not found: \(fullURL.path)")
        return nil
    }

    private func allMDFiles(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        return !urls.isEmpty && urls.allSatisfy {
            $0.pathExtension.lowercased() == "md"
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let petWindow else { return [] }
        let pb = sender.draggingPasteboard
        if DebugLog.enabled {
            let types = pb.types?.map(\.rawValue) ?? []
            let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            DebugLog.log("drag entered — source app: \(source), pasteboard types: \(types)")
        }
        let urls = fileURLs(from: sender)
        let hasObsidian = !obsidianLinks(from: sender).isEmpty

        if urls.contains(where: { $0.isExistingDirectory }),
           petWindow.hasPluginForType?(.folder) == true {
            petScene?.setOpenWide(true)
            return .copy
        }

        if !urls.isEmpty || hasObsidian {
            petScene?.setOpenWide(true)
            return petWindow.courierDragOperation
        }
        let hasPlugin: Bool
        if pb.data(forType: .tiff) != nil || pb.data(forType: .png) != nil {
            hasPlugin = petWindow.hasPluginForType?(.image) ?? false
        } else if let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let url = URL(string: text),
               url.scheme == "http" || url.scheme == "https" {
                hasPlugin = petWindow.hasPluginForType?(.url) ?? false
            } else {
                hasPlugin = petWindow.hasPluginForType?(.text) ?? false
            }
        } else {
            DebugLog.log("drag entered — nothing draggable, rejecting")
            return []
        }
        guard hasPlugin else {
            DebugLog.log("drag entered — no plugin handles this type, rejecting")
            return []
        }
        petScene?.setOpenWide(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let petWindow else { return [] }
        let urls = fileURLs(from: sender)
        if urls.contains(where: { $0.isExistingDirectory }),
           petWindow.hasPluginForType?(.folder) == true {
            return .copy
        }
        if !urls.isEmpty || !obsidianLinks(from: sender).isEmpty {
            return petWindow.courierDragOperation
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        petScene?.setOpenWide(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)

        let fromObsidian = obsidianFileURLs(from: sender)
        if !fromObsidian.isEmpty {
            DebugLog.log("drop: \(fromObsidian.count) obsidian:// link(s) → courier: \(debugFileList(fromObsidian))")
            petWindow?.filesDropped(fromObsidian)
            return true
        }

        if !urls.isEmpty {
            let route = DropRouter.route(
                urls,
                isDirectory: { $0.isExistingDirectory },
                hasFolderPlugin: petWindow?.hasPluginForType?(.folder) == true,
                hasPluginFor: { petWindow?.hasPluginForFileExt?($0, $1) == true }
            )
            if let plugin = route.plugin {
                DebugLog.log("drop: \(plugin.type.rawValue) → plugin dispatch, path=\(plugin.url.path)")
                petWindow?.onPluginDrop?(plugin.type, PluginRunner.Input(
                    type: plugin.type, text: nil,
                    filePath: plugin.url.path, sourceApp: nil
                ))
            }
            if !route.courier.isEmpty {
                DebugLog.log("drop: \(route.courier.count) file(s) → courier: \(debugFileList(route.courier))")
                petWindow?.filesDropped(route.courier)
            }
            return true
        }

        if let (type, input) = PluginDispatch.classifyDrag(sender) {
            DebugLog.log("drop: plugin dispatch, type=\(type.rawValue)")
            petWindow?.onPluginDrop?(type, input)
            return true
        }

        DebugLog.log("drop: unhandled, rejecting")
        petScene?.setOpenWide(false)
        return false
    }
}
