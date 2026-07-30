import AppKit
import SwiftUI

@MainActor
final class PluginPaletteModel: ObservableObject {
    /// A row. The courier is a choice here, not a fallback: a plugin that
    /// matches a dropped file no longer takes it outright, so this palette is
    /// the *only* way to reach delivery for such a drop. See `DropRouter.Route`.
    enum Choice {
        case plugin(PluginManifest, URL)
        case courier

        /// Stable identity for `ForEach`/`scrollTo`. Plugin names are unique
        /// (the registry keys by directory name) and the sentinel can't
        /// collide with one, since a manifest name can't be empty.
        var id: String {
            switch self {
            case .plugin(let manifest, _): return manifest.name
            case .courier: return ""
            }
        }

        var title: String {
            switch self {
            case .plugin(let manifest, _): return manifest.name
            case .courier: return "Deliver to a vault\u{2026}"
            }
        }

        var subtitle: String {
            switch self {
            case .plugin(let manifest, _): return manifest.description
            case .courier: return "Move or copy it into a vault you pick"
            }
        }
    }

    let choices: [Choice]
    @Published var filter = "" {
        didSet { if filter != oldValue { selection = 0 } }
    }
    /// Starts on the first plugin, so ⏎ reproduces what Chestnut did before
    /// the courier row existed: installing a PDF plugin was a deliberate
    /// statement about PDFs, and the prompt is an interception, not a reversal.
    @Published var selection = 0

    /// `offerCourier` comes from the drop site and is never inferred here —
    /// the ⌃⌥C paste path has no deliverable file (its temp copy is deleted
    /// after the run), so offering delivery there would journal an undo record
    /// pointing at a path that no longer exists.
    init(plugins: [(PluginManifest, URL)], offerCourier: Bool) {
        var choices = plugins.map { Choice.plugin($0.0, $0.1) }
        if offerCourier { choices.append(.courier) }
        self.choices = choices
    }

    var filtered: [Choice] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return choices }
        return choices.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    var selected: Choice? {
        let list = filtered
        return list.indices.contains(selection) ? list[selection] : nil
    }

    func moveSelection(by delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let moved = min(max(selection + delta, 0), list.count - 1)
        // At either end nothing moved, so there is nothing to announce.
        guard moved != selection else { return }
        selection = moved
        announceSelection()
    }

    /// Speak the row ↑/↓ just landed on — the same gap, and the same fix, as
    /// `VaultPaletteModel.announceSelection`: focus stays in the filter field
    /// by design, the highlight is a `@Published var` moved by an AppKit key
    /// monitor and owned by no control, so VoiceOver said "text field" however
    /// far down the list the user got.
    ///
    /// This palette is where that matters most. It is now the only route to
    /// the courier for a plugin-matched drop, and the two rows do materially
    /// different things to the user's file: one runs a script over it, the
    /// other moves it into another vault. Choosing blind is not acceptable.
    /// Verified with VoiceOver running — nothing in `make check` can hear.
    private func announceSelection() {
        guard let choice = selected else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: Self.accessibilityLabel(for: choice),
                // The move tracks the user's own keypress, so it outranks
                // whatever the field editor is echoing.
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// One spelling of what a row says, shared by the announcement above and
    /// the row's own label so the two can't drift.
    static func accessibilityLabel(for choice: Choice) -> String {
        let subtitle = choice.subtitle
        return subtitle.isEmpty
            ? choice.title
            : choice.title + ", " + subtitle
    }
}

struct PluginPaletteView: View {
    @ObservedObject var model: PluginPaletteModel
    let onSelect: (PluginPaletteModel.Choice) -> Void
    let onDismiss: () -> Void

    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            // "action", not "plugin": one of these rows is the courier.
            TextField("Pick an action\u{2026}", text: $model.filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onSubmit {
                    if let choice = model.selected { onSelect(choice) }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Divider()

            // Fills the list's space on purpose — see VaultPaletteView.
            if model.filtered.isEmpty {
                Text("No matching action")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(
                                Array(model.filtered.enumerated()),
                                id: \.element.id
                            ) { index, choice in
                                PluginRow(
                                    choice: choice,
                                    isSelected: index == model.selection,
                                    onSelect: { onSelect(choice) },
                                    onHighlight: {
                                        model.selection = index
                                    }
                                )
                                .id(choice.id)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: model.selection) {
                        if let choice = model.selected {
                            proxy.scrollTo(choice.id)
                        }
                    }
                }
            }

            Text("\u{23CE} choose    esc cancel")
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

private struct PluginRow: View {
    let choice: PluginPaletteModel.Choice
    let isSelected: Bool
    let onSelect: () -> Void
    let onHighlight: () -> Void

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(choice.title).fontWeight(.medium).lineLimit(1)
            if !choice.subtitle.isEmpty {
                Text(choice.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
        )
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            hovered = hovering
            if hovering { onHighlight() }
        }
        // For the VO cursor, which can reach rows even though ↑/↓ never move
        // focus to them; `announceSelection` covers the keyboard path.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PluginPaletteModel.accessibilityLabel(for: choice))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@MainActor
final class PluginPalettePanel: PetPanel {
    private let model: PluginPaletteModel

    init(
        plugins: [(PluginManifest, URL)],
        offerCourier: Bool,
        onSelect: @escaping (PluginPaletteModel.Choice) -> Void
    ) {
        model = PluginPaletteModel(plugins: plugins, offerCourier: offerCourier)
        super.init()

        let view = PluginPaletteView(
            model: model,
            onSelect: { [weak self] choice in
                onSelect(choice)
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        host(view)

        installPaletteKeyMonitor(
            moveSelection: { [model] in model.moveSelection(by: $0) },
            hasSelection: { [model] in model.selected != nil },
            primaryAction: { [model] in
                guard let choice = model.selected else { return }
                onSelect(choice)
            }
        )
    }
}
