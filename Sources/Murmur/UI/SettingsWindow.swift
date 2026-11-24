import AVFoundation
import Combine
import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case home, shortcut, microphones, transcription, cleanup, vocabulary, history, lab
    var id: String { rawValue }
    /// Panes shown in the sidebar (the Lab only in developer mode).
    @MainActor static var visible: [Pane] {
        allCases.filter { $0 != .lab || AppSettings.shared.config.developerMode }
    }
    var title: String {
        switch self {
        case .home: "Home"
        case .shortcut: "Shortcut"
        case .microphones: "Microphones"
        case .transcription: "Transcription"
        case .cleanup: "Cleanup"
        case .vocabulary: "Vocabulary"
        case .history: "History"
        case .lab: "Lab"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .shortcut: "keyboard.fill"
        case .microphones: "mic.fill"
        case .transcription: "waveform"
        case .cleanup: "sparkles"
        case .vocabulary: "character.book.closed.fill"
        case .history: "clock.arrow.circlepath"
        case .lab: "flask.fill"
        }
    }
    var color: Color {
        switch self {
        case .home: Theme.accent
        case .shortcut: .gray
        case .microphones: .red
        case .transcription: .blue
        case .cleanup: .purple
        case .vocabulary: .orange
        case .history: .teal
        case .lab: .indigo
        }
    }
}

@MainActor @Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var pane: Pane = .home
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private(set) var window: NSWindow?

    func show(_ pane: Pane? = nil) {
        if let pane { SettingsNavigation.shared.pane = pane }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Murmur"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 780, height: 540)
            w.contentView = NSHostingView(rootView: SettingsRoot())
            w.center()
            w.setFrameAutosaveName("MurmurSettings")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsRoot: View {
    @Bindable var nav = SettingsNavigation.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.pane) {
                Section {
                    ForEach(Pane.visible) { p in
                        Label { Text(p.title) } icon: { IconTile(symbol: p.symbol, color: p.color, size: 20) }
                            .tag(p)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            Group {
                switch nav.pane {
                case .home: HomePane()
                case .shortcut: ShortcutPane()
                case .microphones: MicrophonesPane()
                case .transcription: TranscriptionPane()
                case .cleanup: CleanupPane()
                case .vocabulary: VocabularyPane()
                case .history: HistoryPane()
                case .lab: LabPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .tint(Theme.accent)
    }
}

private struct SidebarFooter: View {
    var body: some View {
        HStack(spacing: 8) {
            AppGlyph(size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Murmur").font(.system(size: 12, weight: .semibold))
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }
}

/// The app mark, drawn in SwiftUI so it's crisp everywhere.
struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(Theme.brand)
            HStack(spacing: size * 0.06) {
                ForEach([0.30, 0.55, 0.85, 0.55, 0.30], id: \.self) { h in
                    Capsule().fill(.white).frame(width: size * 0.085, height: size * 0.62 * h)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Home

struct HomePane: View {
    var history = HistoryStore.shared
    var settings = AppSettings.shared
    @ViewState private var mic = Permissions.microphone
    @ViewState private var ax = Permissions.accessibility
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if mic != .authorized || !ax { permissions }
                stats
                recent
                developer
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .onReceive(poll) { _ in
            mic = Permissions.microphone
            ax = Permissions.accessibility
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private var triggerKeys: [String] {
        let c = settings.config
        switch c.triggerKind {
        case .modifier:
            switch c.triggerModifier {
            case .fn: return ["fn"]
            case .rightOption: return ["right ⌥"]
            case .rightCommand: return ["right ⌘"]
            case .rightControl: return ["right ⌃"]
            }
        case .shortcut: return c.shortcut.displayParts
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            AppGlyph(size: 64)
                .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
            VStack(spacing: 6) {
                Text(greeting).font(.system(size: 30, weight: .bold))
                Text("Speak anywhere. Murmur types it, beautifully.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Hold").foregroundStyle(.secondary)
                HStack(spacing: 5) { ForEach(triggerKeys, id: \.self) { KeyCap(label: $0, large: true) } }
                Text("to talk").foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("tap for hands-free").foregroundStyle(.secondary)
            }
            .font(.system(size: 14, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background.secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.brand.opacity(0.07))
                )
        )
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish setting up").font(.system(size: 15, weight: .semibold))
            VStack(spacing: 0) {
                PermissionRow(symbol: "mic.fill", color: .red, title: "Microphone",
                              detail: "So Murmur can hear you.", granted: mic == .authorized) {
                    if mic == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        Permissions.openPrivacy("Privacy_Microphone")
                    }
                }
                Divider().padding(.leading, 52)
                PermissionRow(symbol: "accessibility", color: .blue, title: "Accessibility",
                              detail: "So Murmur can type into other apps and see your shortcut.", granted: ax) {
                    TextInserter.requestAccessibility()
                    Permissions.openPrivacy("Privacy_Accessibility")
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            StatCard(value: history.wordsThisWeek.formatted(), label: "words this week", symbol: "text.word.spacing", color: Theme.accent)
            StatCard(value: history.averageWPM > 0 ? "\(history.averageWPM)" : "—", label: "words per minute", symbol: "speedometer", color: .orange)
            StatCard(value: history.minutesSaved > 0 ? "\(history.minutesSaved) min" : "—", label: "saved vs. typing", symbol: "hourglass", color: .teal)
        }
    }

    private var developer: some View {
        HStack(spacing: 12) {
            IconTile(symbol: Pane.lab.symbol, color: Pane.lab.color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer mode").font(.system(size: 13, weight: .semibold))
                Text("Adds the Lab: replay recent recordings through other speech models, cleanup models and prompts, side by side.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { settings.config.developerMode },
                                     set: { settings.config.developerMode = $0 }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !history.entries.isEmpty {
                    Button("See all") { SettingsNavigation.shared.pane = .history }.buttonStyle(.link)
                }
            }
            if history.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Your dictations will appear here.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.entries.prefix(4).enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().padding(.leading, 16) }
                        RecentRow(entry: e)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
            }
        }
    }
}

private struct StatCard: View {
    var value: String
    var label: String
    var symbol: String
    var color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
    }
}

private struct RecentRow: View {
    var entry: HistoryEntry
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(entry.textPurged ? "Transcript expired" : (entry.finalText.isEmpty ? (entry.error ?? "—") : entry.finalText))
                .lineLimit(2)
                .foregroundStyle(entry.finalText.isEmpty ? .secondary : .primary)
            Spacer()
            if let app = entry.appName {
                Text(app).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

struct PermissionRow: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String
    var granted: Bool
    var action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 17))
            } else {
                Button("Allow…", action: action).controlSize(.regular).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Shortcut

struct ShortcutPane: View {
    @Bindable var settings = AppSettings.shared
    @ViewState private var launchAtLogin = AppSettings.shared.launchAtLogin

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: Pane.shortcut.symbol, color: Pane.shortcut.color, title: "Shortcut",
                       subtitle: "Hold to talk, release to type. Tap once for hands-free.")
            Form {
                Section {
                    Picker("Trigger", selection: $settings.config.triggerKind) {
                        Text("Modifier key").tag(TriggerKind.modifier)
                        Text("Keyboard shortcut").tag(TriggerKind.shortcut)
                    }
                    .pickerStyle(.segmented)
                    if settings.config.triggerKind == .modifier {
                        Picker("Key", selection: $settings.config.triggerModifier) {
                            ForEach(TriggerModifier.allCases) { Text($0.label).tag($0) }
                        }
                    } else {
                        LabeledContent("Shortcut") { ShortcutRecorder(combo: $settings.config.shortcut) }
                    }
                } footer: {
                    if settings.config.triggerKind == .modifier && settings.config.triggerModifier == .fn {
                        if let action = FnKeySetting.conflictingAction {
                            HStack(spacing: 8) {
                                Label("macOS is set to “\(action)” when you press 🌐/fn, which fights with Murmur. Set “Press 🌐 key to” → “Do Nothing”.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Button("Keyboard Settings…") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                                }
                                .controlSize(.small)
                            }
                            .font(.system(size: 11.5))
                        } else {
                            Label("Set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing” so macOS doesn't also react to fn.",
                                  systemImage: "info.circle")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("How it works") {
                    HowRow(symbol: "hand.point.down.fill", title: "Push to talk", detail: "Hold the key, speak, let go. Text appears where your cursor is.")
                    HowRow(symbol: "hand.tap.fill", title: "Hands-free", detail: "Tap the key once to keep listening. Tap again to finish.")
                    HowRow(symbol: "escape", title: "Cancel", detail: "Press esc at any time to discard the recording.")
                }
                Section("Sounds") {
                    Toggle("Play sounds", isOn: $settings.config.playSounds)
                    if settings.config.playSounds {
                        Picker("Style", selection: $settings.config.soundStyle) {
                            ForEach(SoundStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        LabeledContent("Volume") {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.system(size: 11))
                                Slider(value: $settings.config.soundVolume, in: 0.1...1)
                                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.system(size: 11))
                            }
                            .frame(maxWidth: 240)
                        }
                        LabeledContent("Preview") {
                            HStack(spacing: 6) {
                                ForEach([(Sound.Kind.start, "Start"), (.stop, "Stop"), (.done, "Typed"), (.cancel, "Cancel"), (.error, "Error")], id: \.0) { kind, label in
                                    Button(label) { Sound.play(kind, force: true) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                Section("Behavior") {
                    Toggle("Restore clipboard after pasting", isOn: $settings.config.restoreClipboard)
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: settings.config.triggerKind) { HotkeyManager.shared.install() }
        .onChange(of: settings.config.triggerModifier) { HotkeyManager.shared.install() }
        .onChange(of: settings.config.shortcut) { HotkeyManager.shared.install() }
    }
}

private struct HowRow: View {
    var symbol: String
    var title: String
    var detail: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// What macOS does when 🌐/fn is pressed on its own (System Settings › Keyboard).
enum FnKeySetting {
    /// A human name for the action if macOS also reacts to fn, else nil.
    static var conflictingAction: String? {
        guard let v = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int else { return nil }
        switch v {
        case 1: return "Change Input Source"
        case 2: return "Show Emoji & Symbols"
        case 3: return "Start Dictation"
        default: return nil
        }
    }
}
