import AppKit
import Observation
import Speech

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = MicrophoneManager.shared
        HistoryStore.shared.start()
        setupStatusItem()
        observePhase()

        if E2E.isActive {
            Task { await E2E.run() }
            return
        }

        DictationController.shared.install()
        prewarm()
        if !AppSettings.shared.config.hasOnboarded {
            AppSettings.shared.config.hasOnboarded = true
            SettingsWindowController.shared.show(.home)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    /// Load the on-device model at launch so the first dictation is instant.
    private func prewarm() {
        let c = AppSettings.shared.config
        if c.cleanupEnabled && c.cleanupEngine == .apple { Cleanup.prewarmApple() }
        guard c.engine == .apple else { return }
        let locale = Locale(identifier: c.localeIdentifier)
        let model = c.appleModel
        Task.detached(priority: .utility) {
            do {
                try await AppleSpeech.ensureInstalled(locale: locale, model: model)
                let m = try await AppleSpeech.module(for: locale, model: model)
                let analyzer = SpeechAnalyzer(modules: [m], options: .init(priority: .utility, modelRetention: .processLifetime))
                try await analyzer.prepareToAnalyze(in: nil)
                await analyzer.cancelAndFinishNow()
            } catch {
                NSLog("Murmur: prewarm failed: \(error)")
            }
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let listening = DictationController.shared.phase == .listening
        let toggle = NSMenuItem(title: listening ? "Finish Dictation" : "Start Dictation",
                                action: #selector(toggleDictation), keyEquivalent: "")
        toggle.image = NSImage(systemSymbolName: listening ? "stop.circle" : "mic", accessibilityDescription: nil)
        menu.addItem(toggle)

        let recent = HistoryStore.shared.entries.filter { !$0.finalText.isEmpty }.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent — click to copy", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for e in recent {
                let title = e.finalText.count > 48 ? String(e.finalText.prefix(46)) + "…" : e.finalText
                let item = NSMenuItem(title: title, action: #selector(copyEntry(_:)), keyEquivalent: "")
                item.representedObject = e.finalText
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func toggleDictation() { DictationController.shared.toggleFromMenu() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func observePhase() {
        withObservationTracking {
            _ = DictationController.shared.phase
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observePhase()
            }
        }
    }

    private func updateIcon() {
        let symbol: String = switch DictationController.shared.phase {
        case .listening: "waveform.circle.fill"
        case .processing: "ellipsis.circle"
        default: "waveform"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        img?.isTemplate = true
        statusItem?.button?.image = img
    }
}
