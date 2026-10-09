import AppKit
import SwiftUI

/// One entry of a `MenuButton` menu.
struct MenuEntry {
    var title: String
    var enabled = true
    var checked = false
    var isSeparator = false
    var isHeader = false
    var action: @MainActor () -> Void = {}

    static var separator: MenuEntry { MenuEntry(title: "", isSeparator: true) }
    static func header(_ title: String) -> MenuEntry { MenuEntry(title: title, enabled: false, isHeader: true) }
}

/// An icon button that opens a native NSMenu. SwiftUI's `Menu` inside a popover can close as soon as
/// it opens (first click focuses the popover, redraws dismiss it); NSMenu tracks on its own.
struct MenuButton: NSViewRepresentable {
    let systemImage: String
    var help: String?
    let entries: () -> [MenuEntry]

    func makeCoordinator() -> Coordinator { Coordinator(entries: entries) }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: help)
        let button = NSButton(image: image ?? NSImage(), target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.entries = entries
        button.toolTip = help
    }

    @MainActor
    final class Coordinator: NSObject {
        var entries: () -> [MenuEntry]
        private var actions: [@MainActor () -> Void] = []

        init(entries: @escaping () -> [MenuEntry]) { self.entries = entries }

        @objc func open(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            actions = []
            for entry in entries() {
                if entry.isSeparator { menu.addItem(.separator()); continue }
                if entry.isHeader {
                    menu.addItem(NSMenuItem.sectionHeader(title: entry.title))
                    continue
                }
                let item = NSMenuItem(title: entry.title, action: #selector(run(_:)), keyEquivalent: "")
                item.target = self
                item.tag = actions.count
                item.isEnabled = entry.enabled
                item.state = entry.checked ? .on : .off
                actions.append(entry.action)
                menu.addItem(item)
            }
            let y = sender.isFlipped ? sender.bounds.maxY + 4 : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
        }

        @objc func run(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            let action = actions[sender.tag]
            // After the menu has closed, so actions that show windows or alerts behave.
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
    }
}
