import AppKit
import SwiftUI

/// Palette state shared between the SwiftUI view and the hosting panel, so
/// the panel's AppKit key handling (↑/↓) can move the selection while the
/// filter field keeps focus — command-palette style, no Tab stops involved.
@MainActor
final class VaultPaletteModel: ObservableObject {
    let vaults: [Vault]
    @Published var filter = "" {
        didSet { if filter != oldValue { selection = 0 } }
    }
    @Published var selection = 0
    /// Live pin state for the row icons. Toggling doesn't re-sort `vaults` —
    /// rows staying put under the cursor beats instant reordering; the
    /// pin-first order applies the next time a palette opens.
    @Published var pinnedPath: String?

    init(vaults: [Vault], pinnedPath: String?) {
        self.vaults = vaults
        self.pinnedPath = pinnedPath
    }

    var filtered: [Vault] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return vaults }
        return vaults.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.displayPath.localizedCaseInsensitiveContains(query)
        }
    }

    var selected: Vault? {
        let filtered = filtered
        return filtered.indices.contains(selection) ? filtered[selection] : nil
    }

    func moveSelection(by delta: Int) {
        let filtered = filtered
        guard !filtered.isEmpty else { return }
        let moved = min(max(selection + delta, 0), filtered.count - 1)
        // Already at the end: no move, and so nothing to say. Announcing an
        // unchanged row would report progress that didn't happen.
        guard moved != selection else { return }
        selection = moved
        announceSelection()
    }

    /// Speak the row ↑/↓ just landed on.
    ///
    /// VoiceOver announces the *focused* element, and focus never leaves the
    /// filter field — the highlight is this `@Published var`, moved by an
    /// AppKit key monitor and owned by no control — so arrowing through the
    /// hopper was silent, and a VoiceOver pass heard only "text field" no
    /// matter how far down the list it got. ⏎ then opened a vault the user was
    /// never told was selected.
    ///
    /// **Row traits alone do not fix this**, which is what the audit's L7
    /// sketch proposed: `.isSelected` and a label apply once the VO cursor
    /// visits a row, and reaching a row means leaving the field the palette
    /// deliberately keeps focus in. They are worth having for VO-cursor
    /// exploration and are set below, but the announcement is what makes ↑/↓
    /// speak. Only a real ⌘F5 pass can tell the two apart — this one was
    /// driven by hand, before and after.
    private func announceSelection() {
        guard let vault = selected else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: Self.accessibilityLabel(
                    for: vault, isPinned: vault.path == pinnedPath
                ),
                // Selection tracks the user's own keypress, so it outranks
                // whatever the field editor is echoing and should interrupt it.
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// One spelling of what a row says, shared by the announcement above and
    /// the row's own label so the two can't drift. Open and pinned are a
    /// glowing gem and a pin icon on screen — colour and shape only — so they
    /// have to become words here or they reach a screen reader not at all.
    static func accessibilityLabel(for vault: Vault, isPinned: Bool) -> String {
        var parts = [vault.name, vault.displayPath]
        if vault.isOpen { parts.append("open") }
        if isPinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}

/// Vault Hopper: compact palette listing every vault (open-and-recent first,
/// open ones marked with a glowing gem). Type to filter; ↑/↓ move the
/// selection, ⏎ (or a click) opens it, ⌥⏎ (or right-click) reveals in Finder,
/// ⌘⏎ (or right-click) opens today's daily note — hopper mode only;
/// `onOpenDaily` stays nil when the palette picks a courier destination.
struct VaultPaletteView: View {
    @ObservedObject var model: VaultPaletteModel
    let placeholder: String
    let onOpen: (Vault) -> Void
    let onReveal: (Vault) -> Void
    let onOpenDaily: ((Vault) -> Void)?
    let onTogglePin: (Vault) -> Void
    let onDismiss: () -> Void

    @FocusState private var filterFocused: Bool

    // Visual changes here should be mirrored in the website's re-creation
    // (docs/index.html + docs/chestnut.js).
    var body: some View {
        VStack(spacing: 6) {
            TextField(placeholder, text: $model.filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onSubmit {
                    if let vault = model.selected { onOpen(vault) }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Divider()

            // The panel is a fixed size once open (`PetPanel.host`), so the
            // empty state has to occupy the space the list would have. Left to
            // hug its text it floats centred in a transparent window, which
            // reads as the panel jumping away from the pet.
            if model.filtered.isEmpty {
                Text("No matching vault")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(model.filtered.enumerated()), id: \.element.path) { index, vault in
                                VaultRow(
                                    vault: vault,
                                    isSelected: index == model.selection,
                                    isPinned: vault.path == model.pinnedPath,
                                    onOpen: onOpen,
                                    onReveal: onReveal,
                                    onOpenDaily: onOpenDaily,
                                    onTogglePin: onTogglePin,
                                    onHighlight: { model.selection = index }
                                )
                                .id(vault.path)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: model.selection) {
                        if let vault = model.selected {
                            proxy.scrollTo(vault.path)
                        }
                    }
                }
            }

            // Outside the branch: the key hints are as true with no matches as
            // with some, and a footer that comes and goes changes the layout's
            // shape under a fixed-size panel.
            Text(onOpenDaily == nil
                 ? "⏎ open    ⌥⏎ reveal in Finder    ⌘P pin"
                 : "⏎ open    ⌘⏎ today's note    ⌥⏎ reveal    ⌘P pin")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.bottom, 6)
        }
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .onExitCommand(perform: onDismiss)
        .onAppear { filterFocused = true }
    }
}

private struct VaultRow: View {
    let vault: Vault
    let isSelected: Bool
    let isPinned: Bool
    let onOpen: (Vault) -> Void
    let onReveal: (Vault) -> Void
    let onOpenDaily: ((Vault) -> Void)?
    let onTogglePin: (Vault) -> Void
    let onHighlight: () -> Void

    @State private var rowHovered = false
    @State private var pinHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // The gem: glowing for open vaults, dormant for closed ones.
            Circle()
                .fill(vault.isOpen ? Color.purple : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .shadow(color: vault.isOpen ? .purple.opacity(0.8) : .clear, radius: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(vault.name)
                    .lineLimit(1)
                Text(vault.displayPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Pin toggle: the pinned row always shows its pin; other rows
            // reveal a muted one on hover. Hovering a set pin previews unpin.
            if isPinned || rowHovered {
                Button {
                    onTogglePin(vault)
                } label: {
                    Image(systemName: isPinned
                          ? (pinHovered ? "pin.slash.fill" : "pin.fill")
                          : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(isPinned
                                         ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(.secondary))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { pinHovered = $0 }
                .help(isPinned ? "Unpin" : "Pin as default vault")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
        )
        .onTapGesture { onOpen(vault) }
        .onHover { hovering in
            rowHovered = hovering
            if hovering { onHighlight() }
        }
        .contextMenu {
            if let onOpenDaily {
                Button("Open Today's Daily Note") { onOpenDaily(vault) }
            }
            Button("Reveal in Finder") { onReveal(vault) }
        }
        // For the VO cursor, which can reach the rows even though ↑/↓ never
        // move focus to them; `announceSelection` covers the keyboard path.
        // `.combine` folds the hover-only pin button into the row rather than
        // leaving a bare "pin" button beside it — the pin is still reachable
        // by ⌘P and the row's context menu, both of which VoiceOver reads.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            VaultPaletteModel.accessibilityLabel(for: vault, isPinned: isPinned)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Panel hosting the palette (chrome and dismissal live in PetPanel).
@MainActor
final class VaultPalettePanel: PetPanel {
    private let model: VaultPaletteModel
    private let onPinChange: (String?) -> Void

    init(
        vaults: [Vault],
        placeholder: String = "Jump to vault…",
        pinnedPath: String? = nil,
        onOpenDaily: ((Vault) -> Void)? = nil,
        onPinChange: @escaping (String?) -> Void,
        onSelect: @escaping (Vault) -> Void
    ) {
        model = VaultPaletteModel(vaults: vaults, pinnedPath: pinnedPath)
        self.onPinChange = onPinChange
        super.init()

        // Dismiss before the handler runs so a notice it shows above the pet
        // isn't covered by the closing palette.
        let openDaily: ((Vault) -> Void)? = onOpenDaily.map { handler in
            { [weak self] vault in
                self?.dismiss()
                handler(vault)
            }
        }

        let view = VaultPaletteView(
            model: model,
            placeholder: placeholder,
            onOpen: { [weak self] vault in
                onSelect(vault)
                self?.dismiss()
            },
            onReveal: { vault in
                ObsidianBridge.revealInFinder(path: vault.path)
            },
            onOpenDaily: openDaily,
            onTogglePin: { [weak self] vault in self?.togglePin(vault) },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        host(view)

        // The shared monitor handles ↑/↓/⏎; `extra` adds this palette's
        // chords: ⌘P pins, ⌥⏎ reveals in Finder (also on the rows'
        // right-click menu — the old per-row icon was the palette's only Tab
        // stop), ⌘⏎ opens the daily note.
        installPaletteKeyMonitor(
            moveSelection: { [model] in model.moveSelection(by: $0) },
            hasSelection: { [model] in model.selected != nil },
            primaryAction: { [model] in
                guard let vault = model.selected else { return }
                onSelect(vault)
            },
            extra: { [weak self, model] event in
                switch event.keyCode {
                case 35 where event.modifierFlags.contains(.command):  // ⌘P
                    if let vault = model.selected { self?.togglePin(vault) }
                    return true
                case 36, 76:  // ⏎ variants; a plain ⏎ falls to the shared path
                    guard let vault = model.selected else { return false }
                    if event.modifierFlags.contains(.option) {
                        ObsidianBridge.revealInFinder(path: vault.path)
                        return true
                    }
                    if event.modifierFlags.contains(.command), let openDaily {
                        openDaily(vault)
                        return true
                    }
                    return false
                default:
                    return false
                }
            }
        )
    }

    private func togglePin(_ vault: Vault) {
        model.pinnedPath = model.pinnedPath == vault.path ? nil : vault.path
        onPinChange(model.pinnedPath)
    }
}
