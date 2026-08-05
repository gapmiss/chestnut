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

    /// The cleanup belonging to whoever *opened* this panel, kept apart from
    /// `onClose` because those two have different owners and different
    /// lifetimes.
    ///
    /// `onClose` belongs to the host: `AppDelegate.presentPalette` sets it to
    /// its own bookkeeping and clears it when one palette supersedes another,
    /// so the outgoing panel cannot undo state the incoming one just set up.
    /// A caller that chained its own work onto `onClose` had that work thrown
    /// away by the same line — which is how a plugin save whose vault picker
    /// was replaced lost its clipboard fallback, and with it the plugin's
    /// entire output.
    ///
    /// This one runs on every dismissal, including the one that replaces the
    /// panel, and it is never cleared from outside. Anything that must happen
    /// whatever became of the panel goes here.
    var afterDismiss: (() -> Void)?

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

    /// Speak the state the palette *opens* in, once VoiceOver has had its say.
    ///
    /// The preselected row governs what ⏎ does, and it was the one piece of
    /// palette state never spoken: VoiceOver announces the *focused* element,
    /// focus stays in the filter field by design, and `announceSelection`
    /// fires only on a *move*. A sighted user can see which row is armed; a
    /// VoiceOver user was told the rows exist, in order, on request, and never
    /// which one ⏎ would run.
    ///
    /// **This races VoiceOver, and no delay wins outright.** `.priority: .high`
    /// grants the right to interrupt but does not *order* anything. Measured by
    /// ear, 2026-07-30: posted immediately, it cut the hopper off after the
    /// word "Jump"; at 1800ms the first open is right, while later opens give
    /// VoiceOver time to reach the key-hint footer first, so the hints are read
    /// before the list. Late but spoken was chosen over early and truncating.
    ///
    /// **Do not "fix" this by moving the sentence onto the filter field's
    /// `.accessibilityLabel`.** That is the obvious escape from the race and it
    /// was tried: VoiceOver read only the placeholder and the sentence was
    /// never spoken at all, because focus lands on AppKit's field editor rather
    /// than the SwiftUI element carrying the label. Silence is worse than late.
    ///
    /// Takes the sentence already built, not a closure that builds it later,
    /// so it describes the palette as it opened rather than as it is nearly two
    /// seconds on. `skipIf` is the other half of that bargain: a user who has
    /// started typing has left the state this sentence describes, so it is
    /// dropped rather than spoken stale. They are not left in silence — the
    /// field editor echoes what they type, and ↑/↓ announce from there on. The
    /// task is cancelled in `close()` and re-checks `isVisible`, so a palette
    /// dismissed inside the wait says nothing about a panel that is gone.
    func announceOnOpen(
        _ message: String?,
        skipIf: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        guard let message else { return }
        openingAnnouncement = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.openingAnnouncementDelay))
            guard let self, isVisible else { return }
            if let skipIf, skipIf() { return }
            announceToVoiceOver(message)
        }
    }

    /// How long to let VoiceOver's own focus announcement run first. One word
    /// escaped in 400ms, which puts a five-word phrase ("Jump to vault, edit
    /// text") near two seconds. Erring long is the safer direction: too short
    /// truncates the field's announcement, too long only delays this one.
    /// Tuning this further has diminishing returns — the right ordering
    /// depends on the user's speech rate and on what VoiceOver decides to read
    /// next, neither of which is knowable here.
    static let openingAnnouncementDelay = 1800

    private var openingAnnouncement: Task<Void, Never>?

    override func close() {
        if let paletteKeyMonitor { NSEvent.removeMonitor(paletteKeyMonitor) }
        paletteKeyMonitor = nil
        openingAnnouncement?.cancel()
        openingAnnouncement = nil
        super.close()
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        close()
        onClose?()
        // After the host's bookkeeping, so the caller's cleanup sees the
        // panel already unregistered. Cleared as it runs: `isClosing` means
        // this can only happen once, and holding the closure afterwards would
        // keep whatever it captured alive for as long as the panel object is.
        let caller = afterDismiss
        afterDismiss = nil
        caller?()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}

/// Post a spoken announcement to VoiceOver. Every palette announcement goes
/// through here: the selection these palettes move is a `@Published var` owned
/// by no control, so nothing about it reaches a screen reader unless it is
/// said out loud.
///
/// High priority throughout, and deliberately — each caller tracks either the
/// user's own keypress or the palette opening, so it outranks whatever the
/// filter field's editor is echoing and should interrupt it.
@MainActor
func announceToVoiceOver(_ message: String) {
    NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
    )
}

/// Hover-to-highlight, disarmed until the pointer actually moves.
///
/// Both palettes highlight the row under the pointer, and a panel that appears
/// *underneath* a stationary cursor gets a hover event immediately: the
/// pointer never moved, but the hover state changed, so SwiftUI fires and the
/// palette selects a row nobody picked. Measured 2026-07-30 on the ⌃⌥C path,
/// where the mouse is wherever it was last left — same build, same clipboard,
/// row 3 armed or row 1 armed depending only on where the pointer sat. Paired
/// with a preselected row and a blind ⏎ that silently changes what ⏎ does,
/// which is the contract the plugin picker leans on. AppKit menus already
/// ignore hover until the pointer moves.
///
/// The discriminator is the pointer's position when the palette opened,
/// compared against `NSEvent.mouseLocation` at each hover callback. That is a
/// *query*, not an event delivery, which is why it stands in for a
/// `.mouseMoved` monitor: these panels are non-activating, Chestnut is usually
/// not the frontmost app when one opens, and mouse-moved events are delivered
/// to the active app.
///
/// **Drive this from `.onContinuousHover`, never `.onHover`.** `.onHover`
/// fires on hover-state *change*, so a row suppressed at open time would not
/// highlight again until the pointer left it and came back — moving *within*
/// the row would do nothing, which is worse than the bug being fixed.
/// `.onContinuousHover` fires on movement inside the view, which is what gives
/// the arming something to act on. A row's own hover *styling* still belongs
/// on plain `.onHover`.
struct HoverArming {
    private let origin: CGPoint
    private var armed = false

    init() { origin = NSEvent.mouseLocation }

    /// True once the pointer has moved at all since the palette opened.
    mutating func allowsHighlight() -> Bool {
        if !armed, NSEvent.mouseLocation != origin { armed = true }
        return armed
    }
}
