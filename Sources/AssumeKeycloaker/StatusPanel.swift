import AppKit
import SwiftUI

/// The menu bar panel's window. A non-activating panel takes clicks right away: an NSPopover in a
/// menu bar app needs the app to activate first, so the first click (and the gear menu) got eaten
/// on every other try.
@MainActor
final class StatusPanel: NSPanel {
    private let hosting: PanelHostingView
    private let relay: SizeRelay
    var onClose: (() -> Void)?

    init(rootView: PopoverView) {
        let relay = SizeRelay()
        self.relay = relay
        hosting = PanelHostingView(rootView: PanelRoot(content: rootView, relay: relay))
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

        // The content always fills the window, and only fit(to:) resizes the two together, a moment
        // after the content's size changed. When Auto Layout resized them during SwiftUI's update
        // instead (content pinned to the window's edges), macOS 27 drew whatever appeared in that
        // pass upside down, and native controls not at all.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = background.bounds
        background.addSubview(hosting)
        contentView = background
        relay.onChange = { [weak self] size in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit(to: size) } }
        }
    }

    override var canBecomeKey: Bool { !TestRun.active }
    override var canBecomeMain: Bool { false }

    /// Esc closes it.
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        onClose?()
    }

    /// Where the main column goes (under the menu bar icon), and the screen area to stay inside.
    private var preferredX: CGFloat = 0
    private var area: NSRect = .zero

    /// Shows the panel under `anchor` (the status item button's window frame, in screen coordinates).
    func show(below anchor: NSRect) {
        let size = hosting.intrinsicContentSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        area = screen?.visibleFrame ?? .zero
        preferredX = anchor.midX - PopoverView.mainWidth / 2
        setFrame(NSRect(x: x(forWidth: size.width), y: anchor.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
        if !TestRun.active { makeKey() }
    }

    override var isKeyWindow: Bool { TestRun.active || super.isKeyWindow }

    /// The main column stays under the icon; the snippets drawer opens to its right, and the panel
    /// only shifts left when the drawer wouldn't fit on the screen.
    private func x(forWidth width: CGFloat) -> CGFloat {
        max(min(preferredX, area.maxX - width - 6), area.minX + 6)
    }

    /// Follows the content's size, keeping the top edge where it is.
    private func fit(to size: CGSize) {
        guard isVisible else { return }
        guard abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: x(forWidth: size.width), y: top - size.height, width: size.width, height: size.height),
                 display: true, animate: false)
    }
}

/// Tells the panel the content's natural size whenever it changes.
@MainActor
final class SizeRelay {
    var onChange: ((CGSize) -> Void)?
}

/// The panel's content at its natural size, top-left in the window (which may briefly be bigger or
/// smaller than it, until the panel catches up).
struct PanelRoot: View {
    let content: PopoverView
    let relay: SizeRelay

    var body: some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { relay.onChange?($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Accepts the first click even when the panel isn't key yet.
final class PanelHostingView: NSHostingView<PanelRoot> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
