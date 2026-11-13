import AppKit
import AVFoundation
import SwiftUI

/// CommandLineTools ships without the SwiftUI macro plugin; the typealias resolves to
/// the classic `State` property wrapper instead of the `@State` macro.
typealias ViewState = SwiftUI.State

enum Theme {
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.98)
    static let record = Color(red: 1.0, green: 0.27, blue: 0.33)
    static let brand = LinearGradient(
        colors: [Color(red: 0.36, green: 0.30, blue: 0.98), Color(red: 0.73, green: 0.32, blue: 0.93), Color(red: 1.0, green: 0.45, blue: 0.48)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let polish = LinearGradient(
        colors: [Color(red: 0.62, green: 0.55, blue: 1.0), Color(red: 1.0, green: 0.62, blue: 0.80)],
        startPoint: .leading, endPoint: .trailing)
}

/// A System Settings–style coloured icon tile.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(color.gradient)
            )
    }
}

/// Large pane header: tile, title, one-line explanation.
struct PaneHeader: View {
    var symbol: String
    var color: Color
    var title: String
    var subtitle: String
    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}

/// Keyboard key cap, e.g. for "Hold fn".
struct KeyCap: View {
    var label: String
    var large = false
    var body: some View {
        Text(label)
            .font(.system(size: large ? 22 : 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, large ? 16 : 7)
            .frame(minWidth: large ? 56 : 24, minHeight: large ? 52 : 22)
            .background(
                RoundedRectangle(cornerRadius: large ? 12 : 6, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.18), radius: 0, y: large ? 2 : 1)
                    .shadow(color: .black.opacity(0.08), radius: large ? 6 : 2, y: large ? 3 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: large ? 12 : 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10))
            )
    }
}

/// Selectable card used to choose an engine.
struct ChoiceCard: View {
    var symbol: String
    var title: String
    var detail: String
    var selected: Bool
    var action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3, reservesSpace: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.09) : Color.primary.opacity(hover ? 0.05 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// Click-to-record keyboard shortcut field.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            HStack(spacing: 4) {
                if recording {
                    Text("Type a shortcut…").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(combo.displayParts.enumerated()), id: \.offset) { _, p in KeyCap(label: p) }
                }
            }
            .frame(minWidth: 120, minHeight: 28)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(recording ? Theme.accent.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recording ? Theme.accent : .primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotkeyManager.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // esc cancels
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty || (96...122).contains(Int(e.keyCode)) else { NSSound.beep(); return nil }
            combo = KeyCombo(keyCode: UInt32(e.keyCode), modifiers: mods.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotkeyManager.shared.setSuspended(false)
        }
    }
}

/// A secure field bound to a Keychain item.
struct KeychainField: View {
    var account: Keychain.Account
    var prompt: String
    @ViewState private var value = ""
    @ViewState private var reveal = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if reveal { TextField("", text: $value, prompt: Text(prompt)) }
                else { SecureField("", text: $value, prompt: Text(prompt)) }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onSubmit { Keychain.set(value, for: account) }
            .onChange(of: value) { _, v in Keychain.set(v, for: account) }
            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(reveal ? "Hide" : "Show")
        }
        .onAppear { value = Keychain.get(account) ?? "" }
    }
}

/// Status pill like "● Ready".
struct StatusPill: View {
    enum Tone { case good, warn, bad, neutral }
    var text: String
    var tone: Tone
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
    private var color: Color {
        switch tone {
        case .good: .green
        case .warn: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }
}

/// Live input meter used by the microphone test.
struct LevelMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { i in
                    let on = Float(i) / 24 < level
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(on ? (i > 19 ? Color.orange : Color.green) : Color.primary.opacity(0.1))
                        .frame(width: (g.size.width - 46) / 24)
                }
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.06), value: level)
    }
}

enum Permissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var accessibility: Bool { TextInserter.hasAccessibility }

    static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
