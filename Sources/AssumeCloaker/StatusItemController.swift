import AppKit
import CloakerCore
import SwiftUI

/// The menu bar item: a colored shield + the active env name. Left click opens the panel,
/// right click a quick switcher.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let manager: ConnectionManager
    private var timer: Timer?
    private var lastKey = ""

    init(manager: ConnectionManager) {
        self.manager = manager
        super.init()
        let host = NSHostingController(rootView: PopoverView(manager: manager))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard let button = item.button else { return }
        let overall = manager.overall()
        let busy = manager.sessions.values.contains { $0.operation != nil }
        // Just the env name: time left is in the panel, and sessions renew themselves.
        let title = manager.activeEnv?.displayName ?? ""
        let key = "\(overall.light)|\(busy)|\(title)|\(overall.reasons)"
        guard key != lastKey else { return }
        lastKey = key
        button.image = Self.icon(light: overall.light, busy: busy)
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " \(title)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)])
        button.toolTip = overall.reasons.isEmpty ? "Assume Cloaker: all good" : overall.reasons.joined(separator: "\n")
    }

    static func icon(light: Light, busy: Bool) -> NSImage? {
        let name = busy ? "arrow.triangle.2.circlepath" : (light == .gray ? "shield" : "lock.shield.fill")
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if light != .gray || busy {
            let tint = busy ? Light.yellow.nsColor : light.nsColor
            // Busy arrows are one layer; the shield gets a white lock on the colored shield.
            config = config.applying(.init(paletteColors: busy ? [tint] : [.white, tint]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Assume Cloaker")?
            .withSymbolConfiguration(config)
        image?.isTemplate = (light == .gray && !busy)
        return image
    }

    static func dot(_ light: Light) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            light.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        for env in manager.config.environments {
            let mi = NSMenuItem(title: env.displayName + (env.isProduction ? "  (prod)" : ""),
                                action: #selector(useEnv(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = env.id
            mi.state = env.id == manager.activeEnvID ? .on : .off
            mi.image = Self.dot(manager.light(for: env))
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        if manager.kubeLoggerAvailable {
            let running: Bool = { if case .running = manager.logAgent { return true }; return manager.logAgent == .starting }()
            let logs = NSMenuItem(title: running ? "Stop logs" : "Start logs", action: #selector(toggleLogs), keyEquivalent: "l")
            logs.target = self
            menu.addItem(logs)
            if running {
                let viewer = NSMenuItem(title: "Open log viewer", action: #selector(openViewer), keyEquivalent: "")
                viewer.target = self
                menu.addItem(viewer)
            }
            menu.addItem(.separator())
        }
        let renew = NSMenuItem(title: "Renew active session", action: #selector(renewActive), keyEquivalent: "r")
        renew.target = self
        renew.isEnabled = manager.activeEnv != nil
        menu.addItem(renew)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Assume Cloaker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func useEnv(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let env = manager.config.env(id) else { return }
        manager.use(env)
    }

    @objc private func toggleLogs() {
        if case .stopped = manager.logAgent { manager.startLogs(); return }
        if case .failed = manager.logAgent { manager.startLogs(); return }
        manager.stopLogs()
    }

    @objc private func openViewer() { manager.openLogViewer() }

    @objc private func renewActive() {
        if let env = manager.activeEnv { manager.renewNow(env) }
    }
}
