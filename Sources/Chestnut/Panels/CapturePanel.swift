import AppKit
import SwiftUI

/// Target-vault state shared between the SwiftUI view and the hosting panel,
/// so the panel's AppKit key handling (⌘1…⌘9) can retarget without planting
/// invisible focusable controls in the view (they pollute the Tab loop).
///
/// Also owns the draft text so it survives panel dismiss/reopen cycles
/// (cleared only on successful submit).
@MainActor
final class CaptureModel: ObservableObject {
    let vaults: [Vault]
    @Published var target: Vault
    @Published var draft: String

    init(vaults: [Vault], initialTarget: Vault, draft: String) {
        self.vaults = vaults
        self.target = initialTarget
        self.draft = draft
    }

    /// ⌘1…⌘9 pick the Nth vault (menu order).
    func selectVault(at index: Int) {
        guard vaults.indices.contains(index) else { return }
        target = vaults[index]
    }
}

// MARK: - Markdown toolbar helpers

enum MarkdownAction: CaseIterable {
    case bold, italic, strikethrough, code, codeBlock, heading, task, link

    var label: String {
        switch self {
        case .bold:          "B"
        case .italic:        "I"
        case .strikethrough: "S"
        case .code:          "</>"
        case .codeBlock:     "{}"
        case .heading:       "H"
        case .task:          "☐"
        case .link:          "🔗"
        }
    }

    var tooltip: String {
        switch self {
        case .bold:          "Bold (⌘B)"
        case .italic:        "Italic (⌘I)"
        case .strikethrough: "Strikethrough"
        case .code:          "Inline code"
        case .codeBlock:     "Code block"
        case .heading:       "Heading"
        case .task:          "Task"
        case .link:          "Link (⌘K)"
        }
    }

    var fontWeight: Font.Weight {
        self == .bold ? .bold : .regular
    }

    var isItalic: Bool { self == .italic }

    var isStrikethrough: Bool { self == .strikethrough }

    static func fromHotkey(_ chars: String) -> MarkdownAction? {
        switch chars {
        case "b": .bold
        case "i": .italic
        case "k": .link
        default:  nil
        }
    }

    func apply(text: String, selection: NSRange) -> (result: String, newSelection: NSRange) {
        let nsText = text as NSString
        let selected = nsText.substring(with: selection)
        let hasSelection = selection.length > 0

        switch self {
        case .bold:
            return wrap(text: text, selection: selection, selected: selected,
                        prefix: "**", suffix: "**", placeholder: "bold")
        case .italic:
            return wrap(text: text, selection: selection, selected: selected,
                        prefix: "_", suffix: "_", placeholder: "italic")
        case .strikethrough:
            return wrap(text: text, selection: selection, selected: selected,
                        prefix: "~~", suffix: "~~", placeholder: "strikethrough")
        case .code:
            return wrap(text: text, selection: selection, selected: selected,
                        prefix: "`", suffix: "`", placeholder: "code")
        case .codeBlock:
            let prefix = "```\n"
            let suffix = "\n```"
            if hasSelection {
                let replacement = "\(prefix)\(selected)\(suffix)"
                let result = nsText.replacingCharacters(in: selection, with: replacement)
                return (result, NSRange(location: selection.location + prefix.count,
                                        length: selection.length))
            } else {
                let placeholder = "code"
                let replacement = "\(prefix)\(placeholder)\(suffix)"
                let result = nsText.replacingCharacters(in: selection, with: replacement)
                return (result, NSRange(location: selection.location + prefix.count,
                                        length: placeholder.count))
            }
        case .heading:
            let lineStart = lineStartIndex(in: text, from: selection.location)
            let prefix = "## "
            let result = nsText.mutableCopy() as! NSMutableString
            result.insert(prefix, at: lineStart)
            let newCursor = selection.location + prefix.count
            let newLen = hasSelection ? selection.length : 0
            return (result as String, NSRange(location: newCursor, length: newLen))
        case .task:
            let lineStart = lineStartIndex(in: text, from: selection.location)
            let prefix = "- [ ] "
            let result = nsText.mutableCopy() as! NSMutableString
            result.insert(prefix, at: lineStart)
            let newCursor = selection.location + prefix.count
            let newLen = hasSelection ? selection.length : 0
            return (result as String, NSRange(location: newCursor, length: newLen))
        case .link:
            if hasSelection {
                let replacement = "[\(selected)](url)"
                let result = nsText.replacingCharacters(in: selection, with: replacement)
                let urlStart = selection.location + selected.count + 2
                return (result, NSRange(location: urlStart, length: 3))
            } else {
                let replacement = "[title](url)"
                let result = nsText.replacingCharacters(in: selection, with: replacement)
                return (result, NSRange(location: selection.location + 1, length: 5))
            }
        }
    }

    private func wrap(text: String, selection: NSRange, selected: String,
                      prefix: String, suffix: String, placeholder: String)
        -> (result: String, newSelection: NSRange) {
        if selection.length > 0 {
            let replacement = "\(prefix)\(selected)\(suffix)"
            let result = (text as NSString).replacingCharacters(in: selection, with: replacement)
            return (result, NSRange(location: selection.location + prefix.count,
                                    length: selection.length))
        } else {
            let replacement = "\(prefix)\(placeholder)\(suffix)"
            let result = (text as NSString).replacingCharacters(in: selection, with: replacement)
            return (result, NSRange(location: selection.location + prefix.count,
                                    length: placeholder.count))
        }
    }

    private func lineStartIndex(in text: String, from location: Int) -> Int {
        let ns = text as NSString
        let head = ns.substring(to: min(location, ns.length))
        if let lastNewline = head.lastIndex(of: "\n") {
            return head.distance(from: head.startIndex, to: head.index(after: lastNewline))
        }
        return 0
    }
}

// MARK: - Toolbar button style

struct ToolbarButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
            )
            .onHover { isHovered = $0 }
    }
}

// MARK: - NSTextView wrapper (selection access for toolbar + auto-grow)

struct CaptureTextView: NSViewRepresentable {
    @Binding var text: String
    let onCommandReturn: () -> Void
    let onFormat: (MarkdownAction) -> Void

    static let editorHeight: CGFloat = 140

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptureTextView
        var suppressUpdate = false

        init(_ parent: CaptureTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            suppressUpdate = true
            parent.text = tv.string
            suppressUpdate = false
        }

        @MainActor @objc func handleCommandReturn(_ sender: Any?) {
            parent.onCommandReturn()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = CaptureNSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.drawsBackground = false
        tv.string = text

        tv.autoresizingMask = [.width, .height]
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude
        )
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)

        tv.commandReturnAction = { [weak coord = context.coordinator] in
            coord?.handleCommandReturn(nil)
        }
        tv.formatAction = { [onFormat] action in
            onFormat(action)
        }

        scroll.documentView = tv

        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
        }

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView,
              !context.coordinator.suppressUpdate,
              tv.string != text else { return }
        let sel = tv.selectedRange()
        tv.string = text
        tv.setSelectedRange(sel)
    }

    @MainActor
    static func textView(in view: NSView) -> NSTextView? {
        if let scroll = view as? NSScrollView {
            return scroll.documentView as? NSTextView
        }
        for sub in view.subviews {
            if let found = textView(in: sub) { return found }
        }
        return nil
    }
}

/// NSTextView subclass that intercepts ⌘⏎ and formatting hotkeys (⌘B/⌘I/⌘K).
final class CaptureNSTextView: NSTextView {
    var commandReturnAction: (() -> Void)?
    var formatAction: ((MarkdownAction) -> Void)?

    /// End the typing-coalescing undo group at each newline so ⌘Z walks back
    /// a line at a time — by default an uninterrupted typing burst is one
    /// group, and a reflexive ⌘Z would erase the whole draft.
    override func insertNewline(_ sender: Any?) {
        breakUndoCoalescing()
        super.insertNewline(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command && event.keyCode == 36 {
            commandReturnAction?()
            return true
        }
        if flags == .command,
           let chars = event.charactersIgnoringModifiers,
           let action = MarkdownAction.fromHotkey(chars) {
            formatAction?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Capture view

/// Quick Capture: a small textarea by the pet for markdown thoughts —
/// line breaks, tasks, headings all welcome (⏎ is a newline). A compact
/// formatting toolbar sits above the editor. The footer holds the vault
/// target (remembers the last one) and the Capture button; ⌘⏎ captures,
/// Esc dismisses. Draft text persists across dismiss/reopen until submitted.
struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    let onSubmit: (String, Vault) -> Void
    let onDismiss: () -> Void

    private var isBlank: Bool {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var targetPath: Binding<String> {
        Binding(
            get: { model.target.path },
            set: { path in
                if let vault = model.vaults.first(where: { $0.path == path }) {
                    model.target = vault
                }
            }
        )
    }

    // Visual changes here should be mirrored in the website's re-creation
    // (docs/index.html + docs/chestnut.js).
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(MarkdownAction.allCases, id: \.label) { action in
                    Button {
                        applyFormatting(action)
                    } label: {
                        Text(action.label)
                            .font(.system(size: 11, weight: action.fontWeight))
                            .italic(action.isItalic)
                            .strikethrough(action.isStrikethrough)
                            .frame(width: 26, height: 20)
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    .help(action.tooltip)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .onHover { inside in if inside { NSCursor.arrow.set() } }

            ZStack(alignment: .topLeading) {
                CaptureTextView(
                    text: $model.draft,
                    onCommandReturn: submit,
                    onFormat: { applyFormatting($0) }
                )
                .frame(height: CaptureTextView.editorHeight)
                if model.draft.isEmpty {
                    Text("Capture a thought…")
                        .foregroundStyle(.tertiary)
                        .font(.body)
                        .padding(.leading, 9)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)

            Divider()

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.target.isOpen ? Color.purple : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                    Picker("Target vault", selection: targetPath) {
                        ForEach(model.vaults, id: \.path) { vault in
                            Text(title(for: vault)).tag(vault.path)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 170)
                }
                .help("Vault receiving the capture — ⌘1…⌘9 to switch")

                Spacer(minLength: 8)

                Text("⌘↩")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Capture", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .disabled(isBlank)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .onHover { inside in if inside { NSCursor.arrow.set() } }
        }
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .onExitCommand(perform: onDismiss)
    }

    private func title(for vault: Vault) -> String {
        let duplicated = model.vaults.filter { $0.name == vault.name }.count > 1
        return duplicated ? "\(vault.name) — \(vault.displayPath)" : vault.name
    }

    private func submit() {
        guard !isBlank else { return }
        onSubmit(model.draft, model.target)
    }

    private func applyFormatting(_ action: MarkdownAction) {
        guard let root = NSApp.keyWindow?.contentView,
              let tv = CaptureTextView.textView(in: root) else { return }
        let sel = tv.selectedRange()
        let (newText, newSel) = action.apply(text: model.draft, selection: sel)
        model.draft = newText
        DispatchQueue.main.async {
            tv.setSelectedRange(newSel)
        }
    }
}

// MARK: - Panel

/// Panel hosting the capture bubble (chrome and dismissal live in PetPanel).
@MainActor
final class CapturePanel: PetPanel {
    func setDraft(_ text: String) { model.draft = text }
    private let model: CaptureModel
    private let onDraftChange: (String) -> Void
    private let onTargetChange: (Vault) -> Void
    private var keyMonitor: Any?

    init(
        vaults: [Vault], initialTarget: Vault, draft: String,
        onSubmit: @escaping (String, Vault) -> Void,
        onDraftChange: @escaping (String) -> Void,
        onTargetChange: @escaping (Vault) -> Void
    ) {
        self.model = CaptureModel(vaults: vaults, initialTarget: initialTarget, draft: draft)
        self.onDraftChange = onDraftChange
        self.onTargetChange = onTargetChange
        super.init()
        isMovableByWindowBackground = true

        let view = CaptureView(
            model: model,
            onSubmit: { [weak self] text, vault in
                self?.dismiss()
                onSubmit(text, vault)
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        contentView = hosting
        setContentSize(hosting.fittingSize)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self, event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self.dismiss() }
            return nil
        }
    }

    /// Don't dismiss on focus loss — the capture panel stays open when
    /// switching to Alfred, clipboard managers, etc. Esc or submit closes it.
    override func resignKey() {
        super.resignKey()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1...9).contains(digit) {
            model.selectVault(at: digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func close() {
        onDraftChange(model.draft)
        onTargetChange(model.target)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        super.close()
    }
}
