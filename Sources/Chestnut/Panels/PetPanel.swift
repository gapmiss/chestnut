import AppKit
import SwiftUI

/// Shared chrome for the small panels that pop up beside the pet (Vault
/// Hopper, courier destination picker, capture bubble): borderless, floating,
/// key-without-activating, dismissed on Esc. Losing key focus deliberately
/// does *not* dismiss — every panel persists so a half-typed capture or a
/// half-filtered palette survives a stray click into another app.
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

    /// Host `view` at its fitting size and pin the panel to that size for
    /// good. A filtering palette's content shrinks as the query narrows and
    /// collapses hardest when nothing matches — the list and its footer are
    /// replaced by one line of text. An `NSHostingView` left to drive the
    /// window pushes that collapsed measurement into the window's content
    /// min/max size, AppKit clamps the panel down to it, and backspacing
    /// grows the *content* back but never the window: the full list returns
    /// into a slot two rows too short, scrollbar and all. Sizing is a
    /// one-time decision here, so SwiftUI must not keep voting on it.
    /// Order matters: a hosting view with no sizing options stops reporting a
    /// fitting size at all — it answers 0×0, and the panel opens invisible.
    /// Measure while it still will, then take the vote away.
    func host(_ view: some View) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        hosting.frame.size = size
        contentView = hosting
        setContentSize(size)
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

    /// The palette key monitor every filter-and-list palette shares: ↑/↓ move
    /// the selection while the filter field keeps key focus (the field editor
    /// would otherwise use them as caret moves); ⏎/keypad-enter runs
    /// `primaryAction` and dismisses — unless a text view is first responder,
    /// where the event passes through so the filter field's own onSubmit runs
    /// it. ⏎ with nothing selected is consumed, not passed on. `extra` sees
    /// every key first and consumes by returning true, so a palette can add
    /// chords (the vault palette's ⌘P / ⌥⏎ / ⌘⏎). Removed in `close()`;
    /// subclasses need no teardown of their own.
    func installPaletteKeyMonitor(
        moveSelection: @escaping (Int) -> Void,
        hasSelection: @escaping () -> Bool,
        primaryAction: @escaping () -> Void,
        extra: ((NSEvent) -> Bool)? = nil
    ) {
        paletteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                if let extra, extra(event) { return true }
                switch event.keyCode {
                case 125:  // ↓
                    moveSelection(1)
                    return true
                case 126:  // ↑
                    moveSelection(-1)
                    return true
                case 36, 76:  // ⏎ / keypad enter
                    guard hasSelection() else { return true }
                    if self.firstResponder is NSTextView { return false }
                    primaryAction()
                    self.dismiss()
                    return true
                default:
                    return false
                }
            }
            return consumed ? nil : event
        }
    }

    private var paletteKeyMonitor: Any?

    override func close() {
        if let paletteKeyMonitor { NSEvent.removeMonitor(paletteKeyMonitor) }
        paletteKeyMonitor = nil
        super.close()
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        close()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}
