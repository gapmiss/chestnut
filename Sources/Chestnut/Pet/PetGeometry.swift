import Foundation

/// One display, reduced to the two rects the origin maths needs.
///
/// The geometry takes these rather than an `NSScreen` so it can be exercised
/// by `make check`: `PetWindow` is AppKit and can't join the check target,
/// and an unreachable pet is exactly the failure worth having under test.
/// `PetWindow` builds these from `NSScreen` at the call site.
struct PetScreen: Equatable {
    /// Full display bounds — what a stranded sprite is tested against.
    let frame: NSRect
    /// Bounds minus menu bar and Dock — what a trusted origin is clamped to.
    let visibleFrame: NSRect

    init(frame: NSRect, visibleFrame: NSRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Where the pet window sits, and how a saved position is made safe.
///
/// Pure: no AppKit, no window, no persisted state. Everything here is a
/// function of a size, an origin and the screens it's told about.
enum PetGeometry {
    /// Transparent margins around the sprite: room for the hop and z-drift
    /// above, future panels at the sides, a whisker below the baseline.
    /// `bottom` is also the sprite's baseline within the scene — `PetScene`
    /// reads it from here so the window margin and the scene agree by
    /// construction rather than by two constants that must be kept equal.
    enum Margin {
        static let side: CGFloat = 24
        static let top: CGFloat = 56
        static let bottom: CGFloat = 8
    }

    /// Stand-in when there is no screen to ask — a display list can be empty
    /// mid-reconfiguration, and a plausible rect beats a crash or a zero rect.
    static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

    static func contentSize(for size: AppState.PetSize) -> NSSize {
        let scale = size.pixelScale
        return NSSize(
            width: CGFloat(PetFrames.gridWidth) * scale + Margin.side * 2,
            height: CGFloat(PetFrames.gridHeight) * scale + Margin.bottom + Margin.top
        )
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

    /// Bottom-right of the given visible area, inset by a margin.
    static func defaultOrigin(for contentSize: NSSize, onVisible visible: NSRect) -> NSPoint {
        NSPoint(x: visible.maxX - contentSize.width - 40, y: visible.minY + 40)
    }

    /// Clamp a window origin so the whole sprite sits inside `visible`.
    static func clampedOrigin(
        _ origin: NSPoint, for petSize: AppState.PetSize, onVisible visible: NSRect
    ) -> NSPoint {
        let sprite = petRect(
            inWindowFrame: NSRect(origin: origin, size: contentSize(for: petSize)),
            scale: petSize.pixelScale
        )
        var clamped = origin
        clamped.x += max(0, visible.minX - sprite.minX)
        clamped.x -= max(0, sprite.maxX - visible.maxX)
        clamped.y += max(0, visible.minY - sprite.minY)
        clamped.y -= max(0, sprite.maxY - visible.maxY)
        return clamped
    }

    /// Where to put a hotkey-invoked menu so the whole thing is on screen.
    ///
    /// `popUp(positioning:at:in:)` hangs the menu's top-left corner off the
    /// given point and grows *down*, and when that doesn't fit it scrolls
    /// rather than flipping the way a real context menu does. The pet defaults
    /// to the bottom-right corner, so anchoring at the sprite's top hides most
    /// of the menu behind a scroll arrow. Open downward when there's room and
    /// flip above the sprite when there isn't, then clamp both axes.
    /// Pure geometry, so it can be reasoned about without a screen: `visible`
    /// is the target screen's visible frame, nil when there is none to consult.
    ///
    /// Here rather than on `PetWindow` for the reason the rest of this file
    /// gives: the keyboard route to the menu is what exists *because* the pet
    /// may be unreachable, so a menu positioned off-screen takes Settings,
    /// Undo, Reset Position and Quit with it.
    static func menuOrigin(for menuSize: NSSize, at sprite: NSRect, in visible: NSRect?) -> NSPoint {
        let below = NSPoint(x: sprite.midX, y: sprite.maxY)
        guard let visible, menuSize.height > 0 else { return below }

        // Open downward from the sprite's top when the menu fits; otherwise sit
        // it on the bottom edge of the screen, which puts it above the sprite.
        let y = below.y - menuSize.height < visible.minY
            ? min(visible.maxY, visible.minY + menuSize.height)
            : below.y
        let rightmost = max(visible.minX, visible.maxX - menuSize.width)
        return NSPoint(x: min(max(below.x, visible.minX), rightmost), y: y)
    }

    /// A saved position is only trusted if part of the sprite is on a screen —
    /// displays come and go, and `constrainFrameRect` no longer rescues us.
    /// Trusted positions are still clamped into that screen's visible area.
    ///
    /// `mainVisible` is where the pet lands when the saved origin is untrusted
    /// or absent. Intersection is tested against `frame`, not `visibleFrame`:
    /// a sprite tucked under the Dock is still on a display the user can see,
    /// and clamping will lift it out — whereas resetting it to the default
    /// corner would throw away a position they chose.
    static func validatedOrigin(
        _ saved: NSPoint?, for petSize: AppState.PetSize,
        screens: [PetScreen], mainVisible: NSRect
    ) -> NSPoint {
        let size = contentSize(for: petSize)
        guard let saved else { return defaultOrigin(for: size, onVisible: mainVisible) }
        let sprite = petRect(inWindowFrame: NSRect(origin: saved, size: size),
                             scale: petSize.pixelScale)
        guard let screen = screens.first(where: { $0.frame.intersects(sprite) })
        else { return defaultOrigin(for: size, onVisible: mainVisible) }
        return clampedOrigin(saved, for: petSize, onVisible: screen.visibleFrame)
    }
}
