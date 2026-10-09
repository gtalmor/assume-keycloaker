import AppKit
import SwiftUI

/// The menu bar panel's window. A non-activating panel takes clicks right away: an NSPopover in a
/// menu bar app needs the app to activate first, so the first click (and the gear menu) got eaten
/// on every other try.
@MainActor
final class StatusPanel: NSPanel {
    private let hosting: PanelHostingView
    var onClose: (() -> Void)?

    init(rootView: PopoverView) {
        hosting = PanelHostingView(rootView: rootView)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 392, height: 400),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isReleasedWhenClosed = false  // we keep and reuse it
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        hosting.onResize = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fitContent() } }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc closes it.
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        onClose?()
    }

    /// Shows the panel under `anchor` (the status item button's window frame, in screen coordinates).
    func show(below anchor: NSRect) {
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
        makeKey()
    }

    /// Follows the content's height, keeping the top edge where it is.
    private func fitContent() {
        guard isVisible else { return }
        let size = hosting.fittingSize
        guard abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true, animate: false)
    }
}

/// Accepts the first click even when the panel isn't key yet, and reports size changes.
final class PanelHostingView: NSHostingView<PopoverView> {
    var onResize: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }
}
