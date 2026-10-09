import AppKit
import CloakerCore
import SwiftUI

/// The menu bar item: a colored shield + the active env name. Left click opens the panel,
/// right click a quick switcher.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: StatusPanel
    private var monitors: [Any] = []
    /// A click on the icon can first close the panel (as an "outside" click) and then reach the
    /// icon's action: without this, that same click would reopen it.
    private var closedAt = Date.distantPast
    private let manager: ConnectionManager
    private var timer: Timer?
    private var lastKey = ""

    init(manager: ConnectionManager) {
        self.manager = manager
        panel = StatusPanel(rootView: PopoverView(manager: manager))
        super.init()
        panel.onClose = { [weak self] in
            self?.removeMonitors()
            self?.closedAt = Date()
            self?.item.button?.highlight(false)
        }
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
        } else if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(closedAt) > 0.35 {
            openPanel()
        }
    }

    private func openPanel() {
        guard let anchor = item.button?.window?.frame else { return }
        panel.show(below: anchor)
        installMonitors()
        // Show the icon as selected while the panel is open, like a menu. After the click finishes,
        // since the button clears its highlight on mouse-up.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.item.button?.highlight(true)
            }
        }
    }

    func closePanel() {
        if panel.isVisible { panel.close() }
    }

    /// Close on any click outside: in other apps (global monitor) or in our other windows (local),
    /// but not on the status item itself, which toggles.
    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The icon may be drawn by the system: its clicks show up here too. Let it toggle.
                if let icon = self.item.button?.window?.frame, icon.contains(NSEvent.mouseLocation) { return }
                self.closePanel()
            }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                // Only clicks in our ordinary windows (e.g. Settings) close it: not the panel itself,
                // the status item, or a menu opened from the panel.
                if let window = event.window, window !== self?.panel, window.level == .normal {
                    self?.closePanel()
                }
            }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
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
