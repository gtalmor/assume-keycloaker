import SwiftUI

/// A button that shows what happened: working (spinning / spinner), then a ring that completes into
/// a ✓ (or a red ✗), then back to normal.
struct FeedbackButton: View {
    enum Look {
        case icon(String)
        case text(String, systemImage: String? = nil)
    }

    enum Phase { case idle, working, done, failed }

    let look: Look
    var prominent = false
    var help: String?
    /// Returns whether it worked.
    let action: () async -> Bool

    @State private var phase: Phase = .idle

    var body: some View {
        Group {
            if prominent {
                button.buttonStyle(.borderedProminent)
            } else if case .icon = look {
                button.buttonStyle(.borderless)
            } else {
                button
            }
        }
        .disabled(phase == .working)
        .help(help ?? "")
    }

    private var button: some View {
        Button(action: run) { label }
    }

    @ViewBuilder private var label: some View {
        switch look {
        case .icon(let name):
            indicator(idle: Image(systemName: name), size: 15)
                .frame(width: 18, height: 18)
        case .text(let title, let systemImage):
            HStack(spacing: 4) {
                if phase != .idle || systemImage != nil {
                    indicator(idle: systemImage.map { Image(systemName: $0) } ?? Image(systemName: "circle"), size: 12)
                        .frame(width: 13, height: 13)
                }
                Text(phase == .done ? "Done" : phase == .failed ? "Failed" : title)
            }
        }
    }

    @ViewBuilder private func indicator(idle: Image, size: CGFloat) -> some View {
        switch phase {
        case .idle:
            idle
        case .working:
            if case .icon(let name) = look {
                Image(systemName: name).symbolEffect(.rotate, options: .repeating)
            } else {
                ProgressView().controlSize(.mini)
            }
        case .done:
            RingCheck(size: size, color: .green, symbol: "checkmark")
        case .failed:
            RingCheck(size: size, color: .red, symbol: "xmark")
        }
    }

    private func run() {
        guard phase != .working else { return }
        phase = .working
        Task { @MainActor in
            let ok = await action()
            withAnimation(.easeOut(duration: 0.2)) { phase = ok ? .done : .failed }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeInOut(duration: 0.25)) { phase = .idle }
        }
    }
}

/// A circle that draws itself closed, then a symbol pops in.
struct RingCheck: View {
    var size: CGFloat = 14
    var color: Color = .green
    var symbol = "checkmark"

    @State private var progress: CGFloat = 0
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size / 9), lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(color)
                .scaleEffect(shown ? 1 : 0.2)
                .opacity(shown ? 1 : 0)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { progress = 1 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55).delay(0.28)) { shown = true }
        }
    }
}
