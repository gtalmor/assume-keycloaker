import AppKit
import KeycloakerCore
import SwiftUI

@main
@MainActor
enum AssumeKeycloakerMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "team" { exit(TeamCLI.run(Array(args.dropFirst(2)))) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = ConnectionManager()
    private var statusItem: StatusItemController?
    private lazy var settingsWindow = SettingsWindowController(manager: manager)
    private lazy var snippetWindows = SnippetWindows(manager: manager)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(manager: manager, path: args[i + 1])
            return
        }
        if args.contains("--panel-test") {
            Snapshot.showPanel(manager: manager)
            return
        }
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        installMainMenu()
        manager.openSetupWindow = { [weak self] in
            self?.statusItem?.closePanel()
            self?.settingsWindow.show()
        }
        manager.closePanel = { [weak self] in self?.statusItem?.closePanel() }
        manager.openSettingsPane = { [weak self] pane in
            self?.statusItem?.closePanel()
            self?.settingsWindow.show(pane: pane)
        }
        manager.openSnippetEditor = { [weak self] id in
            self?.statusItem?.closePanel()
            self?.snippetWindows.edit(id)
        }
        manager.askSnippetValues = { [weak self] snippet in
            self?.statusItem?.closePanel()
            self?.snippetWindows.ask(snippet)
        }
        // First team-config refresh shortly after launch.
        Task { try? await Task.sleep(for: .seconds(5)); await manager.refreshTeamConfig() }
        manager.start()
        statusItem = StatusItemController(manager: manager)
    }

    /// Menu bar apps have no menu, so ⌘V/⌘C/⌘A/⌘W would do nothing in text fields without this.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Assume Keycloaker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { settingsWindow.show() }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "assume-keycloaker" || url.scheme == Legacy.urlScheme {
            manager.handleInviteLink(url.absoluteString)
        }
    }
}

/// A --snapshot or --panel-test run: it runs next to the real app while someone is working, so its
/// windows look active but never take the keyboard.
enum TestRun {
    static let active = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--panel-test")
}

/// `AssumeKeycloaker --snapshot out.png`: renders the panel (light + dark) from live state, read-only.
/// Used for docs and for checking the UI without screen-recording access.
@MainActor
enum Snapshot {
    static func run(manager: ConnectionManager, path: String) {
        manager.passive = true
        manager.start()
        manager.showSampleSnippets(sampleSnippets)
        // Let the VPN / reachability / Zscaler checks land first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let base = URL(fileURLWithPath: path).deletingPathExtension().path
            render(manager: manager, appearance: .aqua, to: base + "-light.png")
            for id in ["network", "keycloak", "sso", "snippets", "activity"] { manager.setExpanded(id, true) }
            render(manager: manager, appearance: .aqua, to: base + "-expanded.png")
            for id in ["network", "keycloak", "sso", "snippets", "activity"] { manager.setExpanded(id, false) }
            render(manager: manager, appearance: .darkAqua, to: base + "-dark.png")
            renderView(SidebarPreview(manager: manager).frame(width: 230), appearance: .darkAqua, to: base + "-sidebar.png")
            for pane in SettingsPane.allCases {
                renderView(PaneContent(manager: manager, pane: pane).padding(24).frame(width: 660),
                           appearance: .aqua, to: base + "-\(pane.rawValue).png")
            }
            NSApp.terminate(nil)
        }
    }

    /// Add `docs` to any test mode for screenshots: no "Finish setup" banner.
    /// `AssumeKeycloaker --panel-test`: shows the real panel at the top of the screen, read-only (no
    /// menu bar icon), then a new one with every section expanded. Prints `panel <round> <window
    /// number>` while each is up so `screencapture -l` can check what the window server draws (the PNG
    /// snapshots above skip vibrancy and AppKit controls).
    static func showPanel(manager: ConnectionManager) {
        manager.passive = true
        manager.start()
        manager.showSampleSnippets(CommandLine.arguments.contains("empty") ? [] : sampleSnippets)
        let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let anchor = NSRect(x: frame.midX - 20, y: frame.maxY, width: 40, height: 0)
        if CommandLine.arguments.contains("demo") {
            DemoRecorder(manager: manager).run()
            return
        }
        if CommandLine.arguments.contains("snippets") {
            // The editor, then the prompt, for the first snippet with variables (nothing is saved).
            let windows = SnippetWindows(manager: manager)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard let snippet = manager.snippets.first(where: { !$0.variables.isEmpty }) ?? manager.snippets.first else {
                    NSApp.terminate(nil)
                    return
                }
                windows.edit(snippet.id, selecting: "200")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    print("panel 0 \(windows.editorWindowNumber ?? 0)")
                    fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        windows.closeEditor()
                        windows.ask(snippet)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            print("panel 1 \(windows.promptWindowNumber ?? 0)")
                            fflush(stdout)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withExtendedLifetime(windows) { NSApp.terminate(nil) } }
                        }
                    }
                }
            }
            return
        }
        if CommandLine.arguments.contains("churn") {
            // Sections and the snippets drawer open and close while the panel is up (the window resizes
            // each time).
            for id in ["network", "keycloak", "sso", "snippets", "activity"] { manager.setExpanded(id, false) }
            let panel = StatusPanel(rootView: PopoverView(manager: manager))
            panel.show(below: anchor)
            func step(_ i: Int) {
                guard i < 12 else { NSApp.terminate(nil); return }
                switch i % 3 {
                case 0: manager.toggleSection("network")
                case 1: withAnimation(.easeInOut(duration: 0.15)) { manager.toggleSection("keycloak") }
                default: manager.toggleSection("snippets")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    print("panel \(i) \(panel.windowNumber)")
                    fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { step(i + 1) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { step(0) }
            return
        }
        func show(_ round: Int) {
            for id in ["network", "keycloak", "sso", "snippets", "activity"] { manager.setExpanded(id, round == 1) }
            let panel = StatusPanel(rootView: PopoverView(manager: manager))
            panel.show(below: anchor)
            DispatchQueue.main.asyncAfter(deadline: .now() + (round == 0 ? 10 : 2)) {
                print("panel \(round) \(panel.windowNumber)")
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    panel.close()
                    if round == 1 { NSApp.terminate(nil) } else { show(round + 1) }
                }
            }
        }
        show(0)
    }

    /// Made-up snippets for the test modes, so captures never show the real ones.
    static let sampleSnippets = [
        Snippet(title: "Tail a deployment",
                text: "kubectl --context {context} -n {namespace} logs deploy/{deployment} --tail 200 -f",
                variables: [SnippetVariable(name: "namespace", defaultValue: "web", recent: ["jobs", "web"]),
                            SnippetVariable(name: "deployment", defaultValue: "api")]),
        Snippet(text: "k9s --readonly -n web"),
        Snippet(title: "S3 buckets", text: "aws s3 ls --profile {profile} --region {region}"),
    ]

    private static func render(manager: ConnectionManager, appearance: NSAppearance.Name, to path: String) {
        let root = VStack(alignment: .leading, spacing: 10) {
            MenuBarPreview(manager: manager)
            PopoverView(manager: manager)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor))
        renderView(root, appearance: appearance, to: path)
    }

    private static func renderView<V: View>(_ root: V, appearance: NSAppearance.Name, to path: String) {
        let host = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

/// What the status item looks like for the current state, and for each light.
private struct MenuBarPreview: View {
    let manager: ConnectionManager

    var body: some View {
        HStack(spacing: 16) {
            item(light: manager.overall().light, busy: false, title: currentTitle)
            ForEach([Light.green, .yellow, .red, .gray], id: \.self) { light in
                item(light: light, busy: false, title: "demo")
            }
            item(light: .yellow, busy: true, title: "demo")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
    }

    private var currentTitle: String { manager.activeEnv?.displayName ?? "" }

    private func item(light: Light, busy: Bool, title: String) -> some View {
        HStack(spacing: 3) {
            if let icon = StatusItemController.icon(light: light, busy: busy) { Image(nsImage: icon) }
            Text(title).font(.system(size: 12.5, weight: .medium).monospacedDigit())
        }
    }
}
