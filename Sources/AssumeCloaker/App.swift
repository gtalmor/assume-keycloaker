import AppKit
import CloakerCore
import SwiftUI

@main
@MainActor
enum AssumeCloakerMain {
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
    private lazy var setupWindow = SetupWindowController(manager: manager)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(manager: manager, path: args[i + 1])
            return
        }
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        manager.openSetupWindow = { [weak self] in self?.setupWindow.show() }
        // First team-config refresh shortly after launch.
        Task { try? await Task.sleep(for: .seconds(5)); await manager.refreshTeamConfig() }
        manager.start()
        statusItem = StatusItemController(manager: manager)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "assume-cloaker" { manager.handleInviteLink(url.absoluteString) }
    }
}

/// `AssumeCloaker --snapshot out.png`: renders the panel (light + dark) from live state, read-only.
/// Used for docs and for checking the UI without screen-recording access.
@MainActor
enum Snapshot {
    static func run(manager: ConnectionManager, path: String) {
        manager.passive = true
        manager.start()
        // Let the VPN / reachability / Zscaler checks land first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let base = URL(fileURLWithPath: path).deletingPathExtension().path
            render(manager: manager, appearance: .aqua, to: base + "-light.png")
            render(manager: manager, appearance: .darkAqua, to: base + "-dark.png")
            renderView(SetupView(manager: manager, close: {}).frame(width: 600, height: 1180),
                       appearance: .aqua, to: base + "-setup.png")
            renderView(EnvironmentsView(manager: manager).frame(width: 600, height: 900),
                       appearance: .aqua, to: base + "-envs.png")
            NSApp.terminate(nil)
        }
    }

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
