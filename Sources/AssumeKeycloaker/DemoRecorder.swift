import AppKit
import KeycloakerCore

/// `--panel-test demo`: plays "make a variable, then copy with it" in the real snippet editor and
/// prompt, driving them the way a person would: selecting text, pressing buttons and typing. At each step it prints `frame <name> <window number> <json>`, with
/// where the pointer goes in window points (top-left origin), so a script can capture the frames
/// and draw the pointer over them for the docs animation. Read-only: nothing is saved or copied.
@MainActor
final class DemoRecorder {
    private let manager: ConnectionManager
    private let windows: SnippetWindows
    private let pause: TimeInterval = 1.2

    init(manager: ConnectionManager) {
        self.manager = manager
        windows = SnippetWindows(manager: manager)
    }

    func run() {
        let snippet = Snippet(title: "Tail a deployment", text: "kubectl -n web logs deploy/api --tail 200 -f")
        manager.showSampleSnippets([snippet])
        after(1.5) { [self] in
            windows.edit(snippet.id)
            after(pause) { [self] in editor(snippet) }
        }
    }

    private func editor(_ snippet: Snippet) {
        guard let window = windows.editorWindow, let text = textView(in: window.contentView),
              let range = snippet.text.range(of: "web") else { return quit() }
        let web = NSRange(range, in: snippet.text)
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: web.location, length: 0))
        let start = rect(of: NSRange(location: web.location, length: 1), in: text, window: window)
        let end = rect(of: NSRange(location: web.location + web.length - 1, length: 1), in: text, window: window)
        let from = CGPoint(x: start.minX + 1, y: start.midY), to = CGPoint(x: end.maxX, y: end.midY)
        emit("start", window, ["textStart": from, "textEnd": to])
        let before = buttons(in: window)
        after(pause) { [self] in
            select(1, web, text, window) {
                self.select(2, web, text, window) {
                    self.select(3, web, text, window) {
                        // The button that appeared with the selection: Make "web" a variable.
                        let make = self.buttons(in: window).first { b in !before.contains(where: { $0 === b }) }
                        self.emit("selected", window, ["make": make.map { self.center($0, window) } ?? to])
                        self.after(self.pause) {
                            let shown = self.buttons(in: window)
                            self.press(make) { self.naming(snippet, window, before: shown) }
                        }
                    }
                }
            }
        }
    }

    private func select(_ length: Int, _ web: NSRange, _ text: NSTextView, _ window: NSWindow, then: @escaping () -> Void) {
        text.setSelectedRange(NSRange(location: web.location, length: length))
        after(0.4) { [self] in
            emit("select-\(length)", window, [:])
            after(pause, then)
        }
    }

    private func naming(_ snippet: Snippet, _ window: NSWindow, before: [NSButton]) {
        // The naming form's new buttons are Cancel and Add, Add on the right.
        let add = buttons(in: window).filter { b in !before.contains(where: { $0 === b }) }
            .max { center($0, window).x < center($1, window).x }
        emit("naming", window, ["add": add.map { center($0, window) } ?? .zero])
        after(pause) { [self] in
            press(add) {
                self.emit("made", window, [:])
                self.after(self.pause) { self.prompt(snippet.id) }
            }
        }
    }

    private func prompt(_ id: String) {
        windows.closeEditor()
        guard let snippet = manager.snippets.first(where: { $0.id == id }) else { return quit() }
        windows.ask(snippet)
        after(pause) { [self] in
            guard let window = windows.promptWindow else { return quit() }
            // Copy is the bottom-right button; the field is the first text field.
            let copy = buttons(in: window).max { a, b in
                let pa = center(a, window), pb = center(b, window)
                return pa.y + pa.x / 1000 < pb.y + pb.x / 1000
            }
            let field = fields(in: window.contentView).first
            emit("prompt", window, ["copy": copy.map { center($0, window) } ?? .zero,
                                    "field": field.map { center($0, window) } ?? .zero])
            if !(window.firstResponder is NSTextView), let field { window.makeFirstResponder(field) }
            type(Array("jobs"), typed: 0, window)
        }
    }

    /// Types one character at a time into the focused field, replacing what was selected first.
    private func type(_ chars: [Character], typed: Int, _ window: NSWindow) {
        guard typed < chars.count else {
            after(pause) { [self] in quit() }
            return
        }
        after(0.5) { [self] in
            if let editor = window.firstResponder as? NSTextView {
                if typed == 0 { editor.selectAll(nil) }
                editor.insertText(String(chars[typed]), replacementRange: editor.selectedRange())
            }
            after(0.4) { [self] in
                emit("type-\(typed + 1)", window, [:])
                type(chars, typed: typed + 1, window)
            }
        }
    }

    // MARK: Helpers

    private func emit(_ name: String, _ window: NSWindow, _ points: [String: CGPoint]) {
        let json = points.map { "\"\($0.key)\":[\(Int($0.value.x)),\(Int($0.value.y))]" }.joined(separator: ",")
        print("frame \(name) \(window.windowNumber) {\(json)}")
        fflush(stdout)
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { work() }
    }

    private func quit() {
        withExtendedLifetime(windows) { NSApp.terminate(nil) }
    }

    private func press(_ button: NSButton?, then: @escaping () -> Void) {
        button?.performClick(nil)
        after(0.6, then)
    }

    private func buttons(in window: NSWindow) -> [NSButton] {
        func walk(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(walk)
        }
        return window.contentView.map(walk)?.filter { !$0.isHidden && $0.window != nil } ?? []
    }

    private func fields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let mine = (view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? []
        return mine + view.subviews.flatMap { fields(in: $0) }
    }

    private func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, !text.isFieldEditor { return text }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }

    /// A range of the text in window points, top-left origin.
    private func rect(of range: NSRange, in text: NSTextView, window: NSWindow) -> CGRect {
        let screen = text.firstRect(forCharacterRange: range, actualRange: nil)
        return CGRect(x: screen.minX - window.frame.minX, y: window.frame.maxY - screen.maxY,
                      width: screen.width, height: screen.height)
    }

    /// A view's center in window points, top-left origin.
    private func center(_ view: NSView, _ window: NSWindow) -> CGPoint {
        let r = view.convert(view.bounds, to: nil)
        return CGPoint(x: r.midX, y: window.frame.height - r.midY)
    }
}
