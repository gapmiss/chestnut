import AppKit
import SwiftUI

@MainActor
final class PluginPaletteModel: ObservableObject {
    let plugins: [(manifest: PluginManifest, dir: URL)]
    @Published var filter = "" {
        didSet { if filter != oldValue { selection = 0 } }
    }
    @Published var selection = 0

    init(plugins: [(PluginManifest, URL)]) {
        self.plugins = plugins
    }

    var filtered: [(manifest: PluginManifest, dir: URL)] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return plugins }
        return plugins.filter {
            $0.manifest.name.localizedCaseInsensitiveContains(query)
                || $0.manifest.description
                    .localizedCaseInsensitiveContains(query)
        }
    }

    var selected: (manifest: PluginManifest, dir: URL)? {
        let list = filtered
        return list.indices.contains(selection) ? list[selection] : nil
    }

    func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = min(max(selection + delta, 0), filtered.count - 1)
    }
}

struct PluginPaletteView: View {
    @ObservedObject var model: PluginPaletteModel
    let onSelect: (PluginManifest, URL) -> Void
    let onDismiss: () -> Void

    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            TextField("Pick a plugin\u{2026}", text: $model.filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onSubmit {
                    if let choice = model.selected {
                        onSelect(choice.manifest, choice.dir)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Divider()

            if model.filtered.isEmpty {
                Text("No matching plugin")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(
                                Array(model.filtered.enumerated()),
                                id: \.element.manifest.name
                            ) { index, entry in
                                PluginRow(
                                    name: entry.manifest.name,
                                    description: entry.manifest.description,
                                    isSelected: index == model.selection,
                                    onSelect: {
                                        onSelect(
                                            entry.manifest, entry.dir)
                                    },
                                    onHighlight: {
                                        model.selection = index
                                    }
                                )
                                .id(entry.manifest.name)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: model.selection) {
                        if let choice = model.selected {
                            proxy.scrollTo(choice.manifest.name)
                        }
                    }
                }

                Text("\u{23CE} run    esc cancel")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.bottom, 6)
            }
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
    let name: String
    let description: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onHighlight: () -> Void

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).fontWeight(.medium).lineLimit(1)
            if !description.isEmpty {
                Text(description)
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
    }
}

@MainActor
final class PluginPalettePanel: PetPanel {
    private let model: PluginPaletteModel
    private var keyMonitor: Any?

    init(
        plugins: [(PluginManifest, URL)],
        onSelect: @escaping (PluginManifest, URL) -> Void
    ) {
        model = PluginPaletteModel(plugins: plugins)
        super.init()

        let view = PluginPaletteView(
            model: model,
            onSelect: { [weak self] manifest, dir in
                onSelect(manifest, dir)
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        contentView = hosting
        setContentSize(hosting.fittingSize)

        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self, event.window === self else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                switch event.keyCode {
                case 125:  // down
                    self.model.moveSelection(by: 1)
                    return true
                case 126:  // up
                    self.model.moveSelection(by: -1)
                    return true
                case 36, 76:  // return / keypad enter
                    guard let choice = self.model.selected else {
                        return true
                    }
                    if self.firstResponder is NSTextView {
                        return false
                    }
                    onSelect(choice.manifest, choice.dir)
                    self.dismiss()
                    return true
                default:
                    return false
                }
            }
            return consumed ? nil : event
        }
    }

    override func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        super.close()
    }
}
