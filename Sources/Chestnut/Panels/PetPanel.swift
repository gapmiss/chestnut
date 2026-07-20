import AppKit

/// Shared chrome for the small panels that pop up beside the pet (Vault
/// Hopper, courier destination picker, capture bubble): borderless, floating,
/// key-without-activating, dismissed on Esc or when losing key.
@MainActor
class PetPanel: NSPanel {
    var onClose: (() -> Void)?
    private var isClosing = false

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    /// With no main menu (LSUIElement app), ⌘V/⌘C/⌘X/⌘A/⌘Z have no Edit-menu
    /// key equivalents to fire; route them to the first responder by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (flags, event.charactersIgnoringModifiers) {
        case (.command, "v"):
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case (.command, "c"):
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case (.command, "x"):
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case (.command, "a"):
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case (.command, "z"):
            return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
        case ([.command, .shift], "Z"):
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        default:
            return false
        }
    }

    /// Anchor above the pet window, clamped to the screen.
    func show(above petFrame: NSRect) {
        var origin = NSPoint(
            x: petFrame.midX - frame.width / 2,
            y: petFrame.maxY + 4
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(petFrame) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            if origin.y + frame.height > visible.maxY {
                origin.y = petFrame.minY - frame.height - 4  // flip below
            }
        }
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        close()
        onClose?()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}
