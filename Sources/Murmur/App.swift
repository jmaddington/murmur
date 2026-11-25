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
    private var axTimer: Timer?
    fileprivate var lastAXState = TextInserter.hasAccessibility

    /// Text fields get ⌘X/⌘C/⌘V/⌘A/⌘Z only through main-menu key equivalents;
    /// a menu-bar app has no menu unless we build one.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        submenu("Murmur", [
            item("About Murmur", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide Murmur", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Murmur", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:)), ""),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let window = [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ]
        submenu("Window", window)
        NSApp.windowsMenu = main.items.last?.submenu
        return main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()
        _ = MicrophoneManager.shared
        HistoryStore.shared.start()
        setupStatusItem()
        observePhase()

        if E2E.isActive {
            Task { Demo.isActive ? await Demo.run() : await E2E.run() }
            return
        }

        DictationController.shared.install()
        prewarm()
        Sound.preload()
        UpdateCheck.shared.refreshIfStale()
        if !AppSettings.shared.config.hasOnboarded {
            SetupAssistantController.shared.show()
        }
        // Keep the menu bar badge in sync with the Accessibility grant.
        axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let d = NSApp.delegate as? AppDelegate else { return }
                let trusted = TextInserter.hasAccessibility
                if trusted != d.lastAXState { d.lastAXState = trusted; d.updateIcon() }
            }
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
        if c.engine == .local {
            let m = c.localModel
            // Fresh installs default to Parakeet: fetch it without being asked.
            if m.runtime == .coreML && !LocalModelStore.isInstalled(m) { LocalModelStore.shared.install(m) }
            Task.detached(priority: .utility) {
                switch m.runtime {
                case .coreML: _ = try? await ParakeetRuntime.shared.manager(for: m.parakeetVersion!)
                case .mlx: await MLXRuntime.shared.preload(m)
                }
            }
        }
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
        if !TextInserter.hasAccessibility {
            let ax = NSMenuItem(title: "Allow Accessibility… (needed to type)", action: #selector(grantAccessibility), keyEquivalent: "")
            ax.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(ax)
            menu.addItem(.separator())
        }
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
        let version = NSMenuItem(title: "Murmur \(UpdateCheck.currentVersion) (build \(UpdateCheck.currentBuild))", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        if let latest = UpdateCheck.shared.newerVersion {
            let update = NSMenuItem(title: "Update available: \(latest) — Download…", action: #selector(openLatestRelease), keyEquivalent: "")
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
        }
        UpdateCheck.shared.refreshIfStale()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Setup Assistant…", action: #selector(openSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func checkForUpdates() {
        Task { @MainActor in
            let result = await UpdateCheck.shared.checkNow()
            NSApp.activate()
            let alert = NSAlert()
            switch result {
            case .newer(let v):
                alert.messageText = "Murmur \(v) is available"
                alert.informativeText = "You have \(UpdateCheck.currentVersion). Download the new version from GitHub?"
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(UpdateCheck.releasesURL) }
            case .upToDate:
                alert.messageText = "You're up to date"
                alert.informativeText = "Murmur \(UpdateCheck.currentVersion) (build \(UpdateCheck.currentBuild)) is the latest version."
                alert.runModal()
            case .failed(let why):
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = why
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    @objc private func openSetup() { SetupAssistantController.shared.show() }
    @objc private func openLatestRelease() { NSWorkspace.shared.open(UpdateCheck.releasesURL) }

    @objc private func grantAccessibility() {
        TextInserter.requestAccessibility()
        Permissions.openPrivacy("Privacy_Accessibility")
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

    fileprivate func updateIcon() {
        let symbol: String = switch DictationController.shared.phase {
        case .listening: "waveform.circle.fill"
        case .processing: "ellipsis.circle"
        default: TextInserter.hasAccessibility ? "waveform" : "waveform.badge.exclamationmark"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
        img?.isTemplate = true
        statusItem?.button?.image = img
    }
}

/// Compares this build with the newest GitHub release (public API, no
/// identifiers sent). Checked at launch and when the menu opens, at most
/// every 10 minutes.
@MainActor
final class UpdateCheck {
    static let shared = UpdateCheck()
    static let releasesURL = URL(string: "https://github.com/jmaddington/murmur/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/jmaddington/murmur/releases/latest")!

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    private(set) var latest: String?
    private var checkedAt: Date?
    private var inFlight = false

    /// The latest release's version when it's newer than this build.
    var newerVersion: String? {
        guard let latest, Self.isNewer(latest, than: Self.currentVersion) else { return nil }
        return latest
    }

    func refreshIfStale() {
        guard !E2E.isActive, !inFlight, checkedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        Task { _ = await checkNow() }
    }

    enum Outcome { case upToDate, newer(String), failed(String) }

    /// Ask GitHub for the newest release right now.
    func checkNow() async -> Outcome {
        inFlight = true
        defer { inFlight = false }
        var req = URLRequest(url: Self.api, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Murmur", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                return .failed("GitHub answered with HTTP \(status).")
            }
            latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            checkedAt = Date()
            return newerVersion.map(Outcome.newer) ?? .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Numeric dotted-version comparison ("0.1.10" > "0.1.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
