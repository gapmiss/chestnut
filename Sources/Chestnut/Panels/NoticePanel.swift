import AppKit
import SwiftUI

/// Transient speech bubble from the pet: the quiet receipt for a success
/// ("Captured to Work › 2026-07-16.md"), comic-style tail pointing at the
/// chest. Clicking it follows through (opens the note) — or just dismisses
/// it when there is nothing to follow. It never takes key focus and fades
/// out on its own; failures stay loud NSAlerts.
@MainActor
final class NoticePanel: NSPanel {
    private var fadeTask: Task<Void, Never>?
    private var hosting: NSHostingView<NoticeView>?
    private let clickAction: (() -> Void)?

    /// Fires exactly once when the bubble goes away, whatever the reason
    /// (fade, click, hotkey, replacement) — the notice hotkey unregisters here.
    var onDismiss: (() -> Void)?

    init(title: String, subtitle: String, hotkeyHint: String? = nil, onClick: (() -> Void)? = nil) {
        clickAction = onClick
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

        let openHint: String? = onClick == nil
            ? nil
            : hotkeyHint.map { "Click or \($0) to open" } ?? "Click to open"
        let view = NoticeView(
            title: title,
            subtitle: subtitle,
            openHint: openHint,
            tailX: nil,
            onTap: { [weak self] in self?.performAction() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        contentView = hosting
        setContentSize(hosting.fittingSize)
        self.hosting = hosting
    }

    /// Display-only: the bubble must never pull focus from whatever the user
    /// is typing in.
    override var canBecomeKey: Bool { false }

    /// Sit right on top of the sprite (not the pet *window*, whose frame has
    /// invisible animation headroom), tail tip touching the chest. The tail
    /// keeps pointing at the sprite even when the bubble is clamped at a
    /// screen edge; if there's no room above, slide down over the headroom
    /// rather than flip — the tail must never point at nothing.
    func show(aboveSprite sprite: NSRect, for seconds: TimeInterval = 5) {
        var origin = NSPoint(
            x: sprite.midX - frame.width / 2,
            y: sprite.maxY - 2
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(sprite) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            origin.y = min(origin.y, visible.maxY - frame.height)
        }
        setFrameOrigin(origin)
        hosting?.rootView.tailX = sprite.midX - origin.x
        orderFrontRegardless()

        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.animator().alphaValue = 0
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    /// Follow through, by click or notice hotkey: run the action if there is
    /// one, then dismiss.
    func performAction() {
        clickAction?()
        dismiss()
    }

    func dismiss() {
        fadeTask?.cancel()
        fadeTask = nil
        onDismiss?()
        onDismiss = nil
        close()
    }
}

private struct NoticeView: View {
    let title: String
    let subtitle: String
    let openHint: String?
    /// Tail tip x in bubble coordinates; nil centers it.
    var tailX: CGFloat?
    let onTap: () -> Void

    private var bubble: BubbleShape { BubbleShape(tailX: tailX) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let openHint {
                Text(openHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.bottom, BubbleShape.tailSize.height)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: bubble)
        .overlay(bubble.stroke(.separator, lineWidth: 1))
        .contentShape(bubble)
        .onTapGesture(perform: onTap)
    }
}

/// Rounded rect with a comic-book tail protruding from the bottom edge,
/// drawn as one continuous outline so the stroke has no seam at the joint.
private struct BubbleShape: Shape {
    static let tailSize = CGSize(width: 14, height: 8)
    static let cornerRadius: CGFloat = 10

    var tailX: CGFloat?

    func path(in rect: CGRect) -> Path {
        let r = Self.cornerRadius
        let bodyMaxY = rect.maxY - Self.tailSize.height
        let halfW = Self.tailSize.width / 2
        let tip = min(
            max(tailX ?? rect.midX, rect.minX + r + halfW),
            rect.maxX - r - halfW
        )

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: bodyMaxY - r))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: bodyMaxY - r), radius: r,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        p.addLine(to: CGPoint(x: tip + halfW, y: bodyMaxY))
        p.addLine(to: CGPoint(x: tip, y: rect.maxY))
        p.addLine(to: CGPoint(x: tip - halfW, y: bodyMaxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: bodyMaxY))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: bodyMaxY - r), radius: r,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
