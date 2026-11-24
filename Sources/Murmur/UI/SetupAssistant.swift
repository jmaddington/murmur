import AVFoundation
import SwiftUI

/// First-launch wizard: permissions → speech model → polish → shortcut → try it.
/// Every choice applies immediately; it can be reopened from the menu bar.
@MainActor
final class SetupAssistantController: NSObject, NSWindowDelegate {
    static let shared = SetupAssistantController()
    private(set) var window: NSWindow?

    func show(step: SetupStep = .welcome) {
        SetupState.shared.step = step
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupAssistantView())
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        AppSettings.shared.config.hasOnboarded = true
        if SettingsWindowController.shared.window?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
    }
}

enum SetupStep: Int, CaseIterable { case welcome, speech, polish, shortcut, tryIt }

@MainActor @Observable
final class SetupState {
    static let shared = SetupState()
    var step: SetupStep = .welcome
}

/// What we'd pick for this Mac and language.
enum SetupAdvice {
    static let parakeetLanguages: Set<String> = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                                                 "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
    static let voxtralLanguages: Set<String> = ["en", "es", "fr", "pt", "hi", "de", "nl", "it", "ar", "ru", "zh", "ja", "ko"]

    @MainActor static var language: String {
        Locale(identifier: AppSettings.shared.config.localeIdentifier).language.languageCode?.identifier ?? "en"
    }

    @MainActor static var speech: SpeechChoice {
        if parakeetLanguages.contains(language) { return .parakeet }
        if voxtralLanguages.contains(language) && ProcessInfo.processInfo.physicalMemory >= LocalModel.voxtral.comfortableRAM { return .voxtral }
        return .apple
    }

    enum SpeechChoice: String, CaseIterable, Identifiable {
        case parakeet, apple, voxtral, cloud
        var id: String { rawValue }
    }

    enum PolishChoice: String, CaseIterable, Identifiable {
        case off, apple, cloud
        var id: String { rawValue }
    }
}

struct SetupAssistantView: View {
    @Bindable var state = SetupState.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch state.step {
                case .welcome: WelcomeStep()
                case .speech: SpeechStep()
                case .polish: PolishStep()
                case .shortcut: ShortcutStep()
                case .tryIt: TryItStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40).padding(.top, 44)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(state.step)
            footer
        }
        .frame(width: 640, height: 560)
        .background(.background)
    }

    private var footer: some View {
        HStack {
            if state.step != .welcome {
                Button("Back") { go(-1) }.keyboardShortcut(.cancelAction)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(SetupStep.allCases, id: \.self) { s in
                    Circle().fill(s == state.step ? Theme.accent : Color.primary.opacity(0.15)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if state.step == .tryIt {
                Button("Done") { SetupAssistantController.shared.close() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { go(1) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(.bar)
    }

    private func go(_ d: Int) {
        guard let next = SetupStep(rawValue: state.step.rawValue + d) else { return }
        withAnimation(.easeOut(duration: 0.22)) { state.step = next }
    }
}

private struct StepHeader: View {
    var symbol: String
    var color: Color
    var title: String
    var subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 44)
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }
}

/// A large selectable option row.
private struct OptionRow<Accessory: View>: View {
    var symbol: String
    var title: String
    var badge: String?
    var detail: String
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13.5, weight: .semibold))
                        if let badge {
                            Text(badge).font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accent.opacity(0.15))).foregroundStyle(Theme.accent)
                        }
                    }
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    accessory
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 17))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.5))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension OptionRow where Accessory == EmptyView {
    init(symbol: String, title: String, badge: String? = nil, detail: String, selected: Bool, action: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, badge: badge, detail: detail, selected: selected, action: action) { EmptyView() }
    }
}

// MARK: Steps

private struct WelcomeStep: View {
    @ViewState private var mic = Permissions.microphone
    @ViewState private var ax = Permissions.accessibility
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            AppGlyph(size: 64).padding(.bottom, 14)
            Text("Welcome to Murmur").font(.system(size: 26, weight: .bold))
            Text("Speak anywhere on your Mac and Murmur types it. Two permissions and three quick choices, then you're dictating.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6).padding(.bottom, 24)
            VStack(spacing: 0) {
                PermissionRow(symbol: "mic.fill", color: .red, title: "Microphone",
                              detail: "So Murmur can hear you.", granted: mic == .authorized) {
                    if mic == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                    else { Permissions.openPrivacy("Privacy_Microphone") }
                }
                Divider().padding(.leading, 52)
                PermissionRow(symbol: "accessibility", color: .blue, title: "Accessibility",
                              detail: "So Murmur can type into other apps and hear your shortcut.", granted: ax) {
                    TextInserter.requestAccessibility()
                    Permissions.openPrivacy("Privacy_Accessibility")
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        }
        .onReceive(poll) { _ in mic = Permissions.microphone; ax = Permissions.accessibility }
    }
}

private struct SpeechStep: View {
    @Bindable var settings = AppSettings.shared
    var store = LocalModelStore.shared

    private var current: SetupAdvice.SpeechChoice {
        switch settings.config.engine {
        case .apple: .apple
        case .local: settings.config.localModel == .voxtral ? .voxtral : .parakeet
        case .openrouter, .openaiCompatible: .cloud
        }
    }

    var body: some View {
        let advice = SetupAdvice.speech
        let ram = ProcessInfo.processInfo.physicalMemory >> 30
        VStack(spacing: 10) {
            StepHeader(symbol: "waveform", color: .blue, title: "How should Murmur listen?",
                       subtitle: "Everything except the cloud option runs privately on this Mac.")
            OptionRow(symbol: "bird", title: "Parakeet v3", badge: advice == .parakeet ? "Recommended" : nil,
                      detail: "NVIDIA's open model on the Neural Engine. Top-tier accuracy, text ready a blink after you stop. 25 European languages · 0.5 GB download.",
                      selected: current == .parakeet) { pick(.parakeet) } accessory: { progress(.parakeetV3) }
            OptionRow(symbol: "lock.shield", title: "Apple Speech", badge: advice == .apple ? "Recommended" : nil,
                      detail: "Built into macOS. No download, live preview while you talk, many languages.",
                      selected: current == .apple) { pick(.apple) }
            OptionRow(symbol: "wind", title: "Voxtral Realtime", badge: advice == .voxtral ? "Recommended" : nil,
                      detail: "Mistral's 4B speech LLM via MLX. Great with names and punctuation. 3.6 GB download"
                        + (ram < 16 ? " · slow with \(ram) GB of memory." : "."),
                      selected: current == .voxtral) { pick(.voxtral) } accessory: { progress(.voxtral) }
            OptionRow(symbol: "globe", title: "Cloud (OpenRouter)",
                      detail: "Audio models such as GPT-4o audio. Needs an API key; audio leaves your Mac.",
                      selected: current == .cloud) { pick(.cloud) } accessory: {
                if current == .cloud { KeychainField(account: .openrouter, prompt: "sk-or-…").padding(.top, 4) }
            }
        }
    }

    @ViewBuilder private func progress(_ m: LocalModel) -> some View {
        switch store.state(m) {
        case .installing(let p, let step):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 160)
                Text(step).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.top, 4)
        case .ready where settings.config.engine == .local && settings.config.localModel == m:
            Label("Downloaded", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(.green).padding(.top, 2)
        case .failed(let why):
            Text(why).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2).padding(.top, 2)
        default:
            EmptyView()
        }
    }

    private func pick(_ c: SetupAdvice.SpeechChoice) {
        switch c {
        case .parakeet:
            settings.config.engine = .local; settings.config.localModel = .parakeetV3
            if store.state(.parakeetV3) != .ready { store.install(.parakeetV3) }
        case .voxtral:
            settings.config.engine = .local; settings.config.localModel = .voxtral
            if store.state(.voxtral) != .ready { store.install(.voxtral) }
        case .apple:
            settings.config.engine = .apple
        case .cloud:
            settings.config.engine = .openrouter
            if settings.config.openrouterTranscribeModel.hasPrefix("google/") { settings.config.openrouterTranscribeModel = "openai/gpt-audio-mini" }
        }
    }
}

private struct PolishStep: View {
    @Bindable var settings = AppSettings.shared

    private var current: SetupAdvice.PolishChoice {
        guard settings.config.cleanupEnabled else { return .off }
        return settings.config.cleanupEngine == .apple ? .apple : .cloud
    }

    var body: some View {
        let appleOK = Cleanup.appleAvailability == nil
        VStack(spacing: 10) {
            StepHeader(symbol: "sparkles", color: .purple, title: "Polish your words?",
                       subtitle: "An AI pass removes ums and false starts, keeps only your final self-correction (\u{201C}Tuesday — no wait, Wednesday\u{201D}) and fixes punctuation.")
            OptionRow(symbol: "bolt", title: "Off", badge: appleOK ? nil : "Recommended",
                      detail: "Fastest. Exactly what the speech model heard, plus your vocabulary fixes.",
                      selected: current == .off) { settings.config.cleanupEnabled = false }
            OptionRow(symbol: "apple.intelligence", title: "Apple Intelligence", badge: appleOK ? "Recommended" : nil,
                      detail: appleOK ? "On-device and private. Adds about a second." : (Cleanup.appleAvailability ?? "Unavailable on this Mac."),
                      selected: current == .apple) {
                guard appleOK else { return }
                settings.config.cleanupEnabled = true; settings.config.cleanupEngine = .apple
            }
            .opacity(appleOK ? 1 : 0.5)
            OptionRow(symbol: "globe", title: "Cloud (OpenRouter)",
                      detail: "Fast hosted models such as Claude Haiku. Best results; text leaves your Mac. Compare models later in the Lab.",
                      selected: current == .cloud) {
                settings.config.cleanupEnabled = true; settings.config.cleanupEngine = .openrouter
            } accessory: {
                if current == .cloud {
                    VStack(alignment: .leading, spacing: 6) {
                        KeychainField(account: .openrouter, prompt: "sk-or-…")
                        TextField("Model", text: $settings.config.openrouterCleanupModel).textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

private struct ShortcutStep: View {
    @Bindable var settings = AppSettings.shared

    static func glyph(_ m: TriggerModifier) -> String {
        switch m {
        case .fn: "fn"
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            StepHeader(symbol: "keyboard.fill", color: .gray, title: "Pick your key",
                       subtitle: "Hold it and talk; let go to type. Tap it once for hands-free, tap again to finish. Esc cancels.")
            HStack(spacing: 10) {
                ForEach(TriggerModifier.allCases) { m in
                    let on = settings.config.triggerKind == .modifier && settings.config.triggerModifier == m
                    Button {
                        settings.config.triggerKind = .modifier
                        settings.config.triggerModifier = m
                        HotkeyManager.shared.install()
                    } label: {
                        VStack(spacing: 8) {
                            KeyCap(label: Self.glyph(m), large: true)
                            Text(m.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 118, height: 92)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.035)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(on ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                }
            }
            if settings.config.triggerModifier == .fn, let action = FnKeySetting.conflictingAction {
                HStack(spacing: 8) {
                    Label("macOS is set to “\(action)” on 🌐/fn. Set “Press 🌐 key to” → “Do Nothing”.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Keyboard Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    .controlSize(.small)
                }
                .font(.system(size: 11.5))
            }
            Text("Prefer a combination like ⌥Space? Set it any time in Settings → Shortcut.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

private struct TryItStep: View {
    var settings = AppSettings.shared
    var store = LocalModelStore.shared
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let key = settings.config.triggerKind == .modifier
            ? (settings.config.triggerModifier.label.components(separatedBy: "  ").first ?? "fn")
            : settings.config.shortcut.displayParts.joined()
        VStack(spacing: 14) {
            StepHeader(symbol: "mic.fill", color: .red, title: "Try it",
                       subtitle: "Click in the box, hold \(key), say something, and let go.")
            TextEditor(text: $text)
                .font(.system(size: 15))
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Your words appear here…").font(.system(size: 15)).foregroundStyle(.tertiary)
                            .padding(15).allowsHitTesting(false)
                    }
                }
            if settings.config.engine == .local, case .installing(let p, _) = store.state(settings.config.localModel) {
                Label("\(settings.config.localModel.label) is still downloading (\(Int(p * 100))%). Until then Murmur uses Apple's built-in model.",
                      systemImage: "arrow.down.circle").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Text("Murmur lives in the menu bar (\(Image(systemName: "waveform"))). Settings, history and the Lab are there.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .onAppear { focused = true }
    }
}
