import AppKit
import ApplicationServices

/// Scripted product demo, recorded from the real app:
///
///   Murmur --e2e --demo --out DIR
///
/// Hides other apps, lays a branded backdrop over the desktop, opens a large-
/// type TextEdit document, then dictates scripted utterances through the real
/// pipeline (HUD, on-device transcription, vocabulary, cleanup, paste) while
/// `screencapture -v` records the region. Writes DIR/demo.mov and
/// DIR/timeline.json (when each utterance's audio started, for mixing the voice
/// back in), plus clean HUD stills.
enum Demo {
    static var isActive: Bool { E2E.args.contains("--demo") }

    struct Step {
        var audio: String
        var cleanup: CleanupEngine?
        var vocabulary: [VocabTerm] = []
        var model: String?
    }

    /// Recording region in screen points (top-left origin, as screencapture wants).
    static let region = CGRect(x: 460, y: 371, width: 1000, height: 620)

    @MainActor static func run() async {
        let out = E2E.outDir
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let audioDir = URL(fileURLWithPath: E2E.value("--audio") ?? "tests/e2e/audio")
        AppSettings.shared.config = Config()
        AppSettings.shared.config.playSounds = false
        AppSettings.shared.config.cleanupUsesAppContext = true
        let hasKey = !(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? "").isEmpty
        Keychain.set(E2E.resolveEnv("$OPENROUTER_API_KEY"), for: .openrouter)

        let steps: [Step] = [
            Step(audio: "basic.aiff"),
            Step(audio: "vocab.aiff", vocabulary: [
                VocabTerm(term: "JQ Reyes", soundsLike: ["jay queue reyes", "jake you raised"]),
                VocabTerm(term: "Kubernetes", soundsLike: ["cooper netties"]),
            ]),
            Step(audio: "cleanup.aiff", cleanup: hasKey ? .openrouter : .apple, model: "anthropic/claude-haiku-4.5"),
        ]

        // Stage: hide everything else, cover the desktop.
        let hidden = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0 != NSRunningApplication.current
                && $0.bundleIdentifier != ExternalTarget.bundleID
        }
        for app in hidden {
            app.hide()
            // Some apps ignore hide() from a background process; Accessibility always works.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute as CFString, kCFBooleanTrue)
        }
        try? await Task.sleep(for: .milliseconds(500))
        // Apps that refuse to hide get their windows minimized instead (restored afterwards).
        var minimized: [AXUIElement] = []
        for app in hidden where !app.isHidden {
            var wins: CFTypeRef?
            let el = AXUIElementCreateApplication(app.processIdentifier)
            guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &wins) == .success,
                  let list = wins as? [AXUIElement] else { continue }
            for w in list {
                var m: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
                if (m as? Bool) != true, AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                    minimized.append(w)
                }
            }
            E2E.log("demo: minimized \(list.count) window(s) of \(app.localizedName ?? "?")")
        }
        defer { for w in minimized { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) } }
        try? await Task.sleep(for: .milliseconds(minimized.isEmpty ? 0 : 900))
        let backdrop = Backdrop()
        defer {
            backdrop.close()
            unhide(hidden)
            Keychain.set("", for: .openrouter)
        }
        try? await Task.sleep(for: .milliseconds(800))

        guard let target = await ExternalTarget.open(rtf: true) else {
            E2E.log("demo: could not open TextEdit")
            exit(1)
        }
        // Park TextEdit above where the HUD appears.
        target.setFrame(CGRect(x: region.minX + 50, y: region.minY + 30, width: region.width - 100, height: 330))
        try? await Task.sleep(for: .milliseconds(600))

        // HUD stills over the clean backdrop (for the README).
        await stills(to: out)

        // Record.
        let mov = out.appendingPathComponent("demo.mov")
        try? FileManager.default.removeItem(at: mov)
        let recorder = Process()
        recorder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        recorder.arguments = ["-v", "-x", "-k", "-R", "\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", mov.path]
        try? recorder.run()
        let t0 = Date()
        try? await Task.sleep(for: .seconds(1.5))

        var timeline: [[String: Any]] = []
        for (i, step) in steps.enumerated() {
            var cfg = AppSettings.shared.config
            cfg.engine = .apple
            cfg.vocabulary = step.vocabulary
            cfg.cleanupEnabled = step.cleanup != nil
            cfg.cleanupEngine = step.cleanup ?? .apple
            if let m = step.model { cfg.openrouterCleanupModel = m }
            AppSettings.shared.config = cfg

            let url = audioDir.appendingPathComponent(step.audio)
            let src = FileSource(url: url, realtime: true)
            timeline.append(["audio": url.path, "start": Date().timeIntervalSince(t0)])
            DictationController.shared.begin(source: src)
            await src.waitUntilDone()
            try? await Task.sleep(for: .milliseconds(250))
            let entry = await DictationController.shared.stop(insert: target.isFrontmost)?.value
            E2E.log("demo step \(i + 1): “\(entry?.finalText ?? "")”")
            try? await Task.sleep(for: .seconds(1.6))
            if i < steps.count - 1 && target.isFrontmost {
                pressReturn(times: 2)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        try? await Task.sleep(for: .seconds(1.5))
        recorder.interrupt() // SIGINT finalises the movie
        recorder.waitUntilExit()

        let data = try! JSONSerialization.data(withJSONObject: ["region": [region.minX, region.minY, region.width, region.height], "steps": timeline], options: .prettyPrinted)
        try? data.write(to: out.appendingPathComponent("timeline.json"))
        target.screenshot(to: out.appendingPathComponent("textedit-result.png"))
        target.close()
        E2E.log("demo recorded → \(mov.path)")
        backdrop.close()
        for w in minimized { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        unhide(hidden)
        Keychain.set("", for: .openrouter)
        exit(0)
    }

    @MainActor private static func stills(to dir: URL) async {
        let ctl = DictationController.shared
        let wave: [Float] = (0..<DictationController.barCount).map { (i: Int) -> Float in
            let x = Double(i)
            let swing: Double = abs(sin(x * 0.55))
            let envelope: Double = 0.6 + 0.4 * cos(x * 0.21)
            return Float(0.25 + 0.7 * swing * envelope)
        }
        let states: [(String, () -> Void)] = [
            ("listening", { ctl.debugSet(phase: .listening, partial: "Let's move the design review to Wednesday at three", levels: wave) }),
            ("handsfree", { ctl.debugSet(phase: .listening, levels: wave, latched: true) }),
            ("polishing", { ctl.debugSet(phase: .processing("Polishing")) }),
            ("done", { ctl.debugSet(phase: .done("Let's move the design review to Wednesday at 3 o'clock.")) }),
        ]
        guard let screen = NSScreen.main else { return }
        for (name, apply) in states {
            apply()
            try? await Task.sleep(for: .milliseconds(700))
            guard let w = HUDController.shared.window else { continue }
            let f = w.frame
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", "\(Int(f.minX)),\(Int(screen.frame.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))",
                           dir.appendingPathComponent("hud-\(name).png").path]
            try? p.run()
            p.waitUntilExit()
        }
        ctl.debugSet(phase: .hidden)
        HUDController.shared.window?.orderOut(nil)
    }

    private static func unhide(_ apps: [NSRunningApplication]) {
        for app in apps {
            app.unhide()
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute as CFString, kCFBooleanFalse)
        }
    }

    private static func pressReturn(times: Int) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<times {
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

/// Full-screen branded backdrop that sits just above the desktop, hiding
/// wallpaper and icons but staying below every normal window.
@MainActor
final class Backdrop {
    private let window: NSWindow

    init() {
        let frame = NSScreen.main?.frame ?? .zero
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.contentView = BackdropView(frame: frame)
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }

    private final class BackdropView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(colors: [
                NSColor(srgbRed: 0.10, green: 0.09, blue: 0.22, alpha: 1),
                NSColor(srgbRed: 0.30, green: 0.18, blue: 0.45, alpha: 1),
                NSColor(srgbRed: 0.72, green: 0.38, blue: 0.48, alpha: 1),
            ])?.draw(in: bounds, angle: 35)
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), .clear])?
                .draw(in: NSBezierPath(ovalIn: bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.15)), relativeCenterPosition: .zero)
        }
    }
}
