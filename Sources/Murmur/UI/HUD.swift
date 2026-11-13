import AppKit
import SwiftUI

/// A borderless, non-activating floating panel that never steals focus from
/// the app you're dictating into.
final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController {
    static let shared = HUDController()
    private var panel: HUDPanel?

    func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        // The SwiftUI view animates itself out; just drop the window afterwards.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if DictationController.shared.phase == .hidden { self.panel?.orderOut(nil) }
        }
    }

    var window: NSWindow? { panel }

    private func makePanel() -> HUDPanel {
        let p = HUDPanel()
        let host = NSHostingView(rootView: HUDView(controller: DictationController.shared))
        host.sizingOptions = []
        host.frame = p.contentRect(forFrameRect: p.frame)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 18))
    }
}

// MARK: - View

struct HUDView: View {
    @Bindable var controller: DictationController
    @Namespace private var glass

    private var visible: Bool { controller.phase != .hidden }

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if showsPreview {
                PreviewBubble(text: controller.partial)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
            if visible {
                pill
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: controller.phase)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showsPreview)
        .animation(.easeOut(duration: 0.18), value: controller.partial)
        .environment(\.colorScheme, .dark)
    }

    private var showsPreview: Bool {
        guard !controller.partial.isEmpty else { return false }
        switch controller.phase {
        case .listening, .processing: return true
        default: return false
        }
    }

    @ViewBuilder private var pill: some View {
        HStack(spacing: 12) {
            leading
            center
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(HUDSurface(shape: Capsule(), tint: tint))
        .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
        .contentShape(.capsule)
    }

    private var tint: Color {
        switch controller.phase {
        case .error: Color(red: 0.32, green: 0.04, blue: 0.07).opacity(0.86)
        default: Color.black.opacity(0.80)
        }
    }

    @ViewBuilder private var leading: some View {
        switch controller.phase {
        case .listening:
            RecordingDot()
        case .processing(let stage):
            Image(systemName: stage == "Polishing" ? "sparkles" : "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(stage == "Polishing" ? AnyShapeStyle(Theme.polish) : AnyShapeStyle(.white))
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 18)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white, .green)
                .symbolEffect(.bounce, value: controller.phase)
        case .copied:
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white, .yellow)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var center: some View {
        switch controller.phase {
        case .listening:
            Waveform(levels: controller.levels)
                .frame(width: 150, height: 26)
        case .processing(let stage):
            ShimmerText(text: stage == "Polishing" ? "Polishing" : "Transcribing")
        case .done(let text):
            Text("\(text.split(whereSeparator: \.isWhitespace).count) words")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
        case .copied:
            Text("Copied — press ⌘V")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        case .error(let msg):
            Text(msg)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if controller.phase == .listening {
            HStack(spacing: 6) {
                if let start = controller.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Self.clock(ctx.date.timeIntervalSince(start)))
                            .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                if controller.latched {
                    HUDButton(symbol: "xmark", help: "Cancel (esc)") { controller.cancel(silently: false) }
                    HUDButton(symbol: "stop.fill", prominent: true, help: "Finish") { controller.stop() }
                }
            }
            .transition(.opacity)
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct RecordingDot: View {
    @ViewState private var on = false
    var body: some View {
        Circle()
            .fill(Theme.record)
            .frame(width: 9, height: 9)
            .shadow(color: Theme.record.opacity(0.9), radius: on ? 6 : 2)
            .scaleEffect(on ? 1.0 : 0.82)
            .frame(width: 18)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Scrolling, center-weighted level bars.
struct Waveform: View {
    var levels: [Float]
    var body: some View {
        GeometryReader { geo in
            let n = levels.count
            let spacing: CGFloat = 3
            let w = max(2, (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<n, id: \.self) { i in
                    let pos = Double(i) / Double(max(n - 1, 1))
                    let envelope = 0.45 + 0.55 * sin(pos * .pi)       // taller in the middle
                    let h = max(3, CGFloat(Double(levels[i]) * envelope) * geo.size.height)
                    Capsule()
                        .fill(.white.opacity(0.55 + 0.45 * Double(levels[i])))
                        .frame(width: w, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.interpolatingSpring(stiffness: 260, damping: 22), value: levels)
        }
    }
}

private struct ShimmerText: View {
    var text: String
    @ViewState private var phase: CGFloat = -1
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.4)
                }
                .mask(Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)))
            }
            .frame(minWidth: 150)
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

private struct HUDButton: View {
    var symbol: String
    var prominent = false
    var help: String
    var action: () -> Void
    @ViewState private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(prominent ? .black : .white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(prominent ? .white : .white.opacity(hover ? 0.28 : 0.16)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct PreviewBubble: View {
    var text: String
    var body: some View {
        Text(tail)
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(.white.opacity(0.95))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: tail.count < 56, vertical: true)
            .frame(maxWidth: tail.count < 56 ? nil : 440)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(HUDSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.74)))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
    private var tail: String {
        guard text.count > 120 else { return text }
        return "…" + text.suffix(118)
    }
}

/// Near-black blurred surface with a hairline top highlight: legible over any
/// content, light or dark.
private struct HUDSurface<S: InsettableShape>: View {
    var shape: S
    var tint: Color
    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(tint)
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }
    }
}
