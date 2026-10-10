import AppKit
import KeycloakerCore
import SwiftUI

/// The snippet editor (title, text, which parts are variables) and the prompt that asks for a
/// snippet's variables before copying it. Both are non-activating panels, like the menu bar panel:
/// they take typing without bringing the app forward, so the terminal you paste into stays in front.
@MainActor
final class SnippetWindows: NSObject, NSWindowDelegate {
    private let manager: ConnectionManager
    private var editor: KeyPanel?
    private var prompt: KeyPanel?

    init(manager: ConnectionManager) { self.manager = manager }

    var editorWindow: NSWindow? { editor }
    var promptWindow: NSWindow? { prompt }
    var editorWindowNumber: Int? { editor?.windowNumber }
    var promptWindowNumber: Int? { prompt?.windowNumber }

    /// `selecting` (for --panel-test) starts with that part of the text selected and being named.
    func edit(_ id: String, selecting: String? = nil) {
        editor?.close()
        let view = SnippetEditorView(manager: manager, id: id, selecting: selecting) { [weak self] in self?.editor?.close() }
        let panel = makePanel(view, title: "Snippet", size: NSSize(width: 580, height: 600), resizable: true)
        panel.minSize = NSSize(width: 500, height: 460)
        editor = panel
        present(panel)
    }

    func closeEditor() { editor?.close() }

    func ask(_ snippet: Snippet) {
        finishPrompt()
        let view = SnippetPromptView(manager: manager, snippet: snippet) { [weak self] in self?.finishPrompt() }
        let panel = makePanel(view, title: snippet.label, size: nil, resizable: false)
        panel.delegate = self
        prompt = panel
        present(panel)
    }

    /// A fixed-size panel: these never resize themselves (a window resized from inside a SwiftUI
    /// update misdraws on macOS 27, see StatusPanel).
    private func makePanel<V: View>(_ view: V, title: String, size: NSSize?, resizable: Bool) -> KeyPanel {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let width = size?.width ?? SnippetPromptView.width
        let height = size?.height ?? host.sizeThatFits(in: CGSize(width: width, height: 2000)).height
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: style, backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: width, height: height))
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }

    /// Centered on the screen in use, a bit above the middle (like the alerts).
    private func present(_ panel: NSPanel) {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let area = screen.visibleFrame, size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2,
                                         y: min(area.maxY - size.height, area.minY + area.height * 2 / 3 - size.height / 2)))
        }
        panel.orderFrontRegardless()
        if !TestRun.active { panel.makeKey() }
    }

    /// Clicking somewhere else cancels the prompt, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === prompt { finishPrompt() }
    }

    private func finishPrompt() {
        guard let panel = prompt else { return }
        prompt = nil
        panel.delegate = nil
        panel.close()
    }
}

/// A panel that takes typing while the app stays in the background. Without the app in front its
/// Edit menu doesn't get ⌘V and friends, so they're sent to the focused field here.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { !TestRun.active }
    override var isKeyWindow: Bool { TestRun.active || super.isKeyWindow }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector? = switch (key, flags.contains(.shift)) {
            case ("v", false): #selector(NSText.paste(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("x", false): #selector(NSText.cut(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            case ("w", false): #selector(NSWindow.performClose(_:))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// `{name}` as a small capsule: variables in the accent color, environment fill-ins in green.
struct TokenPill: View {
    let name: String
    let color: Color

    var body: some View {
        Text(Snippet.token(name))
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: Editor

struct SnippetEditorView: View {
    let manager: ConnectionManager
    let id: String
    let close: () -> Void
    @State private var selection: NSRange
    @State private var naming: Naming?
    @State private var showHelp = false
    @FocusState private var nameFocused: Bool

    init(manager: ConnectionManager, id: String, selecting: String? = nil, close: @escaping () -> Void) {
        self.manager = manager
        self.id = id
        self.close = close
        let snippet = manager.snippets.first { $0.id == id }
        var start = NSRange(location: 0, length: 0)
        var naming: Naming?
        if let snippet, let selecting, let range = snippet.text.range(of: selecting) {
            start = NSRange(range, in: snippet.text)
            let suggestion = snippet.suggestion(for: range)
            naming = Naming(range: start, value: selecting, name: suggestion.name, field: suggestion.field)
        }
        _selection = State(initialValue: start)
        _naming = State(initialValue: naming)
    }

    /// The "make this a variable" form: the selection it replaces and the name being typed.
    struct Naming: Equatable {
        var range: NSRange
        var value: String
        var name: String
        var field: String?
    }

    var body: some View {
        if let snippet = manager.snippets.first(where: { $0.id == id }) {
            editor(snippet)
        } else {
            VStack(spacing: 10) {
                Text("This snippet was deleted.").foregroundStyle(.secondary)
                Button("Close", action: close)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editor(_ s: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Title (optional)", text: Binding(get: { s.title ?? "" },
                                                        set: { t in change { $0.title = t.isEmpty ? nil : t } }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))
            VStack(alignment: .leading, spacing: 8) {
                SnippetTextView(text: Binding(get: { s.text }, set: { t in change { $0.text = t } }),
                                selection: $selection, variables: Set(s.variables.map(\.name)))
                    .frame(minHeight: 110)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                markBar(s)
            }
            if !s.variables.isEmpty { variablesList(s) }
            fillIns
            VStack(alignment: .leading, spacing: 4) {
                Text(s.activeVariables.isEmpty ? "Copies as" : "Copies as (with the values it starts with)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(manager.render(s))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer(minLength: 0)
            HStack {
                Button("Delete snippet", role: .destructive) {
                    manager.deleteSnippet(id)
                    close()
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Edits the current version of the snippet and saves it.
    private func change(_ edit: (inout Snippet) -> Void) {
        guard var s = manager.snippets.first(where: { $0.id == id }) else { return }
        edit(&s)
        manager.updateSnippet(s)
    }

    @ViewBuilder
    private func markBar(_ s: Snippet) -> some View {
        if let n = naming {
            namingForm(s, n)
        } else if let range = Range(selection, in: s.text), !range.isEmpty {
            if let problem = s.problem(selecting: range) {
                hint(problem, icon: "exclamationmark.triangle")
            } else {
                HStack(spacing: 10) {
                    Button {
                        let suggestion = s.suggestion(for: range)
                        naming = Naming(range: selection, value: String(s.text[range]), name: suggestion.name, field: suggestion.field)
                    } label: {
                        Label("Make “\(Self.short(s.text[range]))” a variable", systemImage: "curlybraces")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("You'll be asked for it when you copy.").font(.caption).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                hint("Select the part that changes (a namespace, a pod, a tag…) to make it a variable.", icon: "hand.point.up.left")
                ForEach(s.undeclaredTokens, id: \.self) { name in
                    HStack(spacing: 8) {
                        TokenPill(name: name, color: .orange)
                        Text("isn't a variable yet").font(.caption).foregroundStyle(.secondary)
                        Button("Make it one") { change { $0.declareVariable(name) } }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func namingForm(_ s: Snippet, _ n: Naming) -> some View {
        let problem = s.problem(naming: n.name)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Name")
                TextField("name", text: Binding(get: { naming?.name ?? "" }, set: { naming?.name = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 170)
                    .focused($nameFocused)
                    .onSubmit(commitNaming)
                Text("default “\(Self.short(n.value[...]))”").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Cancel") { naming = nil }.keyboardShortcut(.cancelAction)
                Button("Add", action: commitNaming).disabled(problem != nil)
            }
            .controlSize(.small)
            if let problem { hint(problem, icon: "exclamationmark.triangle") }
            if let field = n.field {
                Button("Or use {\(field)} from the active environment (now \(fieldValue(field))), without asking") {
                    useField(field, n)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { nameFocused = true }
    }

    private func commitNaming() {
        guard let n = naming, var s = manager.snippets.first(where: { $0.id == id }) else { return }
        guard let range = Range(n.range, in: s.text), String(s.text[range]) == n.value else {
            naming = nil  // the text changed underneath
            return
        }
        guard s.makeVariable(range, name: n.name) else { return }
        manager.updateSnippet(s)
        selection = NSRange(location: n.range.location + (Snippet.token(n.name) as NSString).length, length: 0)
        naming = nil
    }

    private func useField(_ field: String, _ n: Naming) {
        change { s in
            if let range = Range(n.range, in: s.text), String(s.text[range]) == n.value { s.insertField(field, at: range) }
        }
        selection = NSRange(location: n.range.location + (Snippet.token(field) as NSString).length, length: 0)
        naming = nil
    }

    private func variablesList(_ s: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Variables").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(s.variables, id: \.name) { v in
                    GridRow {
                        TokenPill(name: v.name, color: .accentColor)
                        TextField("default", text: Binding(get: { v.defaultValue },
                                                           set: { d in change { $0.setDefault(d, for: v.name) } }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Group {
                            if s.text.contains(Snippet.token(v.name)) {
                                Color.clear
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("Not in the text any more, so it isn't asked for")
                            }
                        }
                        .frame(width: 16, height: 16)
                        Button {
                            change { $0.removeVariable(v.name) }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Back to plain text (its default)")
                    }
                }
            }
            Text("Each copy asks for these, starting from the last values you used.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fillIns: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("From the active environment").font(.headline)
                Button {
                    showHelp.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("What these are, and how variables work")
                .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                    SnippetHelp(manager: manager).padding(16).frame(width: 400)
                }
            }
            HStack(spacing: 6) {
                ForEach(Snippet.fields, id: \.self) { field in
                    Button {
                        insert(field)
                    } label: {
                        TokenPill(name: field, color: .green)
                    }
                    .buttonStyle(.plain)
                    .help("Insert at the cursor. Now: \(fieldValue(field))")
                }
            }
            Text("Click one to insert it: it's filled in when you copy, never asked for.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func insert(_ field: String) {
        let at = selection
        change { s in
            if let range = Range(at, in: s.text) { s.insertField(field, at: range) }
        }
        selection = NSRange(location: at.location + (Snippet.token(field) as NSString).length, length: 0)
    }

    /// What `{field}` fills in right now.
    private func fieldValue(_ field: String) -> String {
        manager.fillInValue(field) ?? "no active environment"
    }

    private func hint(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary)
    }

    static func short(_ text: Substring) -> String {
        text.count > 24 ? text.prefix(24) + "…" : String(text)
    }
}

/// A plain-text editor for commands: no smart quotes, dashes or autocorrect; `{variables}` in the
/// accent color, `{fill-ins}` in green, unknown `{words}` in orange. Reports the selection.
struct SnippetTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let variables: Set<String>

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = Coordinator.font
        tv.string = text
        context.coordinator.highlight(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        let length = (text as NSString).length
        if tv.string != text { tv.string = text }
        if tv.selectedRange() != selection, selection.location + selection.length <= length {
            tv.setSelectedRange(selection)
        }
        context.coordinator.highlight(tv)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        var parent: SnippetTextView
        var updating = false

        init(_ parent: SnippetTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let tv = notification.object as? NSTextView else { return }
            let range = tv.selectedRange()
            if parent.selection != range { parent.selection = range }
        }

        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let plain: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.textColor]
            storage.beginEditing()
            storage.setAttributes(plain, range: NSRange(location: 0, length: storage.length))
            for (name, range) in Snippet.tokens(in: tv.string) {
                let color: NSColor = parent.variables.contains(name) ? .controlAccentColor
                    : (Snippet.fields.contains(name) ? .systemGreen : .systemOrange)
                storage.addAttributes([.foregroundColor: color, .backgroundColor: color.withAlphaComponent(0.16)],
                                      range: NSRange(range, in: tv.string))
            }
            storage.endEditing()
            tv.typingAttributes = plain
        }
    }
}

// MARK: Help

/// How snippets work, for someone new to them: copying, pinning, variables, and what each
/// environment fill-in gives right now.
struct SnippetHelp: View {
    let manager: ConnectionManager
    /// Smaller type, for the drawer.
    var compact = false

    static let meanings: [(name: String, meaning: String)] = [
        ("env", "the active environment, as named in this app"),
        ("profile", "its AWS profile (what AWS_PROFILE is set to)"),
        ("region", "its AWS region"),
        ("cluster", "its EKS cluster name"),
        ("account", "its AWS account ID"),
        ("context", "its kubectl context (the cluster's ARN)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            step("cursorarrow.click", "Click a snippet to copy it, then paste with ⌘V.")
            step("pin", "Pin clipboard: copy any text first (a command from Terminal, say), then pin it. The editor opens so you can name it.")
            step("curlybraces", "Variables: in the editor, select the part that changes (a namespace, a pod…) and click Make variable. Every copy asks for it, starting from the last value you used.")
            step("bolt.horizontal", "Fill-ins come from the active environment, so they're never asked for:")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: compact ? 5 : 7) {
                ForEach(Self.meanings, id: \.name) { item in
                    GridRow(alignment: .firstTextBaseline) {
                        TokenPill(name: item.name, color: .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.meaning).font(.system(size: compact ? 11 : 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(manager.fillInValue(item.name).map { "now: \($0)" } ?? "no active environment")
                                .font(.system(size: compact ? 10 : 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(.leading, compact ? 0 : 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("For example").font(.system(size: compact ? 10.5 : 11.5)).foregroundStyle(.secondary)
                Text("kubectl --context {context} -n {namespace} get pods")
                    .font(.system(size: compact ? 10.5 : 11.5, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                Text("fills in the context and asks for the namespace.")
                    .font(.system(size: compact ? 10.5 : 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 16)
            Text(text).font(.system(size: compact ? 11 : 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Prompt

/// Asks for a snippet's variables (starting from the last values used), then copies it.
struct SnippetPromptView: View {
    static let width: CGFloat = 470
    let manager: ConnectionManager
    let snippet: Snippet
    let done: () -> Void
    @State private var values: [String: String]
    @FocusState private var focus: String?

    init(manager: ConnectionManager, snippet: Snippet, done: @escaping () -> Void) {
        self.manager = manager
        self.snippet = snippet
        self.done = done
        _values = State(initialValue: Dictionary(snippet.activeVariables.map { ($0.name, $0.initialValue) }) { a, _ in a })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "curlybraces.square.fill").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snippet.label).font(.headline).lineLimit(1)
                    Text("Fill in, then copy").font(.caption).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(snippet.activeVariables, id: \.name) { v in
                    GridRow {
                        TokenPill(name: v.name, color: .accentColor).gridColumnAlignment(.trailing)
                        TextField(v.defaultValue.isEmpty ? v.name : v.defaultValue, text: binding(v.name))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .focused($focus, equals: v.name)
                        Menu {
                            Button("Default: \(v.defaultValue.isEmpty ? "(empty)" : v.defaultValue)") { values[v.name] = v.defaultValue }
                            if !v.recent.isEmpty {
                                Section("Recent") {
                                    ForEach(v.recent, id: \.self) { value in Button(value) { values[v.name] = value } }
                                }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("The default and recent values")
                    }
                }
            }
            Text(manager.render(snippet, values: values))
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(3, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("⏎ copy · esc cancel").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Copy") {
                    manager.copySnippet(snippet, values: values)
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 16)
        .frame(width: Self.width)
        .onAppear { focus = snippet.activeVariables.first?.name }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }
}
