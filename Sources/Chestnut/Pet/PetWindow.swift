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
    var canUndoDelivery: (() -> Bool)?
    /// Quick Capture: menu → Capture… (the global hotkey lands in the delegate).
    var onCapture: (() -> Void)?
    var onUndoCapture: (() -> Void)?
    var canUndoCapture: (() -> Bool)?
    var installedPlugins: (() -> [PluginManifest])?
    var isPluginEnabled: ((String) -> Bool)?
    var togglePlugin: ((String) -> Void)?
    var onOpenPluginsFolder: (() -> Void)?
    /// Menu → Edit Configuration…; the delegate opens config.json.
    var onEditConfiguration: (() -> Void)?

    private var state: AppState
    /// Value readouts on the two Settings slider rows, updated live during a
    /// drag. Weak: the menu owns them, and they die with the menu.
    private weak var noticeDurationReadout: NSTextField?
    private weak var opacityReadout: NSTextField?
    /// Hand-edited settings: read-only here, never written back.
    private let config: Config

    /// Transparent margins around the sprite: room for the hop and z-drift
    /// above, future panels at the sides, a whisker below the baseline.
    enum Margin {
        static let side: CGFloat = 24
        static let top: CGFloat = 56
        static let bottom: CGFloat = PetScene.baselineY
    }

    static func contentSize(for size: AppState.PetSize) -> NSSize {
        let scale = size.pixelScale
        return NSSize(
            width: CGFloat(PetFrames.gridWidth) * scale + Margin.side * 2,
            height: CGFloat(PetFrames.gridHeight) * scale + Margin.bottom + Margin.top
        )
    }

    static func defaultOrigin(for contentSize: NSSize) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: screen.maxX - contentSize.width - 40,
            y: screen.minY + 40
        )
    }

    /// The sprite's current on-screen rect — the anchor for the notice
    /// bubble's tail (the window frame itself has invisible headroom).
    var spriteFrame: NSRect {
        Self.petRect(inWindowFrame: frame, scale: state.size.pixelScale)
    }

    /// The sprite's rect within a window frame (frame minus the margins).
    static func petRect(inWindowFrame frame: NSRect, scale: CGFloat) -> NSRect {
        NSRect(
            x: frame.minX + Margin.side,
            y: frame.minY + Margin.bottom,
            width: frame.width - Margin.side * 2,
            height: CGFloat(PetFrames.gridHeight) * scale
        )
    }

    /// Clamp a window origin so the whole sprite sits inside `screen`'s
    /// visible frame (below the menu bar, above the Dock).
    static func clampedOrigin(
        _ origin: NSPoint, for petSize: AppState.PetSize, on screen: NSScreen?
    ) -> NSPoint {
        guard let visible = screen?.visibleFrame else { return origin }
        let size = contentSize(for: petSize)
        let sprite = petRect(
            inWindowFrame: NSRect(origin: origin, size: size),
            scale: petSize.pixelScale
        )
        var clamped = origin
        clamped.x += max(0, visible.minX - sprite.minX)
        clamped.x -= max(0, sprite.maxX - visible.maxX)
        clamped.y += max(0, visible.minY - sprite.minY)
        clamped.y -= max(0, sprite.maxY - visible.maxY)
        return clamped
    }

    /// A saved position is only trusted if part of the sprite is on a screen —
    /// displays come and go, and constrainFrameRect no longer rescues us.
    /// Trusted positions are still clamped into the visible area.
    static func validatedOrigin(_ saved: NSPoint?, for petSize: AppState.PetSize) -> NSPoint {
        let size = contentSize(for: petSize)
        guard let saved else { return defaultOrigin(for: size) }
        let sprite = petRect(
            inWindowFrame: NSRect(origin: saved, size: size),
            scale: petSize.pixelScale
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(sprite) })
        else { return defaultOrigin(for: size) }
        return clampedOrigin(saved, for: petSize, on: screen)
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
        // Visual changes here should be mirrored in the website's re-creation
        // (docs/chestnut.js, renderMenu).
        let menu = NSMenu()

        menu.addItem(menuItem("Vaults…", #selector(toggleHopper), hotkey: config.hotkeys.hopper))
        menu.addItem(menuItem("Capture…", #selector(beginCapture), hotkey: config.hotkeys.capture))

        menu.addItem(.separator())
        menu.addItem(menuItem("Undo Last Delivery", #selector(undoDelivery)))
        menu.addItem(menuItem("Undo Last Capture", #selector(undoCapture)))

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

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// A plain action row targeting this window, optionally showing the key
    /// equivalent of a configured hotkey.
    private func menuItem(
        _ title: String, _ action: Selector, hotkey: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let hotkey, let (key, mods) = Self.menuEquivalent(for: hotkey) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
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

    /// Everything you set once: two sliders, three toggles, two escape hatches.
    /// Deliberately flat — nothing in here opens a further submenu, so the menu
    /// never reaches a third level.
    private func settingsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()

        let opacity = sliderRow(
            label: "Opacity",
            hint: "How solid Chestnut looks",
            value: state.opacity,
            range: AppState.opacityRange,
            action: #selector(opacityChanged(_:)),
            readout: Self.percentLabel
        )
        opacityReadout = opacity.readout
        submenu.addItem(opacity.item)

        let notice = sliderRow(
            label: "Notice Bubble",
            hint: "How long a notice bubble stays on screen",
            value: state.noticeDuration,
            range: AppState.noticeDurationRange,
            action: #selector(noticeDurationChanged(_:)),
            readout: Self.secondsLabel
        )
        noticeDurationReadout = notice.readout
        submenu.addItem(notice.item)

        submenu.addItem(.separator())
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

    /// One row shape for both sliders: label, slider, value. Fixed label and
    /// readout widths (and monospaced digits) keep the two sliders aligned with
    /// each other and stop `1s` → `30s` from shoving the track sideways.
    /// `hint` becomes the row's tooltip — a slider row has no room to explain
    /// itself, and "Opacity" is self-evident where a duration isn't.
    private func sliderRow(
        label: String,
        hint: String,
        value: Double,
        range: ClosedRange<Double>,
        action: Selector,
        readout: (Double) -> String
    ) -> (item: NSMenuItem, readout: NSTextField) {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: self,
            action: action
        )
        slider.isContinuous = true

        let title = NSTextField(labelWithString: label)
        title.font = .menuFont(ofSize: 0)
        title.widthAnchor.constraint(equalToConstant: Self.sliderLabelWidth).isActive = true

        let valueLabel = NSTextField(labelWithString: readout(value))
        valueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular
        )
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: Self.sliderReadoutWidth).isActive = true

        let row = NSStackView(views: [title, slider, valueLabel])
        row.toolTip = hint
        // Taller than a normal menu row on purpose: a slider knob is ~20pt, so
        // at 24pt two stacked rows put their knobs 4pt apart and read as one
        // mashed block. The vertical air is what makes them legible as a pair.
        row.edgeInsets = NSEdgeInsets(top: 6, left: 21, bottom: 6, right: 14)
        // NSMenu sizes itself to its widest item: the two rows must declare the
        // same width or the submenu jumps between them.
        row.frame = NSRect(x: 0, y: 0, width: Self.sliderRowWidth, height: 32)
        row.autoresizingMask = [.width]

        let item = NSMenuItem()
        item.view = row
        return (item, valueLabel)
    }

    private static let sliderRowWidth: CGFloat = 290
    private static let sliderLabelWidth: CGFloat = 96
    private static let sliderReadoutWidth: CGFloat = 34

    /// Whole seconds only: a bubble that lingers 7.4s isn't a distinct choice
    /// from one that lingers 7.
    private static func secondsLabel(_ seconds: Double) -> String {
        "\(Int(seconds.rounded()))s"
    }

    private static func percentLabel(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        alphaValue = sender.doubleValue
        opacityReadout?.stringValue = Self.percentLabel(sender.doubleValue)
        state.opacity = sender.doubleValue
        // The action fires for every tick of a drag; persist only on the final
        // event (mouse-up, or a direct click on the track).
        if NSApp.currentEvent?.type != .leftMouseDragged {
            onStateChange?(state)
        }
    }

    @objc private func noticeDurationChanged(_ sender: NSSlider) {
        let seconds = sender.doubleValue.rounded()
        noticeDurationReadout?.stringValue = Self.secondsLabel(seconds)
        state.noticeDuration = seconds
        // Like the opacity slider: the action fires on every tick of a drag,
        // so persist only on the final event (mouse-up, or a click on the track).
        if NSApp.currentEvent?.type != .leftMouseDragged {
            onStateChange?(state)
        }
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

    /// Translate a config hotkey string into an NSMenuItem key equivalent.
    /// Display-only — the actual hotkey is Carbon-registered.
    static func menuEquivalent(for binding: String) -> (String, NSEvent.ModifierFlags)? {
        let raw = binding.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty, raw != "none", raw != "disabled" else { return nil }
        let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        let modMap: [String: NSEvent.ModifierFlags] = [
            "control": .control, "ctrl": .control,
            "option": .option, "alt": .option,
            "command": .command, "cmd": .command,
            "shift": .shift,
        ]
        let keyMap: [String: String] = [
            "space": " ", "tab": "\t", "return": "\r", "enter": "\r",
            "escape": "\u{1B}", "esc": "\u{1B}",
            "delete": "\u{08}", "backspace": "\u{08}",
        ]

        var mods: NSEvent.ModifierFlags = []
        var key: String?
        for part in parts {
            if let m = modMap[part] {
                mods.insert(m)
            } else if let k = keyMap[part] {
                if key != nil { return nil }
                key = k
            } else if part.count == 1 {
                if key != nil { return nil }
                key = part
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        return (key, mods)
    }

    @objc private func toggleHopper() { onToggleHopper?() }

    @objc private func beginCapture() { onCapture?() }

    @objc private func undoDelivery() { onUndoDelivery?() }

    @objc private func undoCapture() { onUndoCapture?() }

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
        if menuItem.action == #selector(undoDelivery) {
            return canUndoDelivery?() == true
        }
        if menuItem.action == #selector(undoCapture) {
            return canUndoCapture?() == true
        }
        return true
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

    private func obsidianLink(from sender: NSDraggingInfo) -> ObsidianOpenLink? {
        guard let raw = sender.draggingPasteboard.string(forType: .URL) else { return nil }
        return ObsidianOpenLink(raw)
    }

    private func obsidianFileURL(from sender: NSDraggingInfo) -> URL? {
        guard let link = obsidianLink(from: sender) else { return nil }
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
        let hasObsidian = obsidianLink(from: sender) != nil

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
        if !urls.isEmpty || obsidianLink(from: sender) != nil {
            return petWindow.courierDragOperation
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        petScene?.setOpenWide(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)

        if let resolved = obsidianFileURL(from: sender) {
            DebugLog.log("drop: obsidian:// URL resolved to \(resolved.path) → courier")
            petWindow?.filesDropped([resolved])
            return true
        }

        if !urls.isEmpty {
            if let dir = urls.first(where: { $0.isExistingDirectory }),
               petWindow?.hasPluginForType?(.folder) == true {
                DebugLog.log("drop: folder → plugin dispatch, path=\(dir.path)")
                petWindow?.onPluginDrop?(.folder, PluginRunner.Input(
                    type: .folder, text: nil,
                    filePath: dir.path, sourceApp: nil
                ))
                let rest = urls.filter { !$0.isExistingDirectory }
                if !rest.isEmpty {
                    petWindow?.filesDropped(rest)
                }
                return true
            }

            let mdURLs = urls.filter { $0.pathExtension.lowercased() == "md" }
            let nonMD = urls.filter { $0.pathExtension.lowercased() != "md" }
            if let first = nonMD.first {
                let type = PluginDispatch.extensionToType(first.pathExtension)
                let ext = first.pathExtension.lowercased()
                if petWindow?.hasPluginForFileExt?(type, ext) == true {
                    DebugLog.log("drop: non-.md file → plugin dispatch, type=\(type.rawValue) ext=\(ext)")
                    petWindow?.onPluginDrop?(type, PluginRunner.Input(
                        type: type, text: nil,
                        filePath: first.path, sourceApp: nil
                    ))
                    if !mdURLs.isEmpty {
                        petWindow?.filesDropped(mdURLs)
                    }
                    return true
                }
            }
            DebugLog.log("drop: \(urls.count) file(s) → courier")
            petWindow?.filesDropped(urls)
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
