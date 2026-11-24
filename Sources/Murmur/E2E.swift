import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI

/// Scriptable end-to-end harness.
///
///   Murmur --e2e --out DIR [--cases cases.json] [--screenshots]
///
/// Runs each case's audio file through the *real* pipeline (HUD, analyzer,
/// vocabulary, cleanup, insertion, history), asserts on the output, captures
/// screenshots of every pane and HUD state in light & dark, and writes
/// DIR/report.json. Exits non-zero on any failure. Settings and history are
/// isolated from the user's real ones.
enum E2E {
    static let args = CommandLine.arguments
    static var isActive: Bool { args.contains("--e2e") }
    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static var outDir: URL { URL(fileURLWithPath: value("--out") ?? NSTemporaryDirectory() + "murmur-e2e") }

    struct Case: Decodable {
        var name: String
        var audio: String
        var engine: TranscriptionEngine?
        var appleModel: AppleSpeechModel?
        var localModel: LocalModel?
        var cleanup: CleanupEngine?
        var vocabulary: [VocabTerm]?
        var expectContains: [String]?
        var expectNotContains: [String]?
        var insert: Bool?
        var customUrl: String?
        var apiKey: String?
        var model: String?
        /// Overrides `model` for the transcription step only.
        var transcribeModel: String?
        var cleanupSendsAudio: Bool?
        var style: String?
        var customPrompt: String?
        var requiresEnv: String?
        var mock: Bool?
        /// Capabilities this case needs: apple_speech, apple_intelligence.
        var requires: [String]?
    }

    @MainActor private static var capabilityCache: [String: Bool] = [:]

    @MainActor private static func has(_ capability: String) async -> Bool {
        if let v = capabilityCache[capability] { return v }
        let v: Bool
        switch capability {
        case "apple_speech":
            let locale = Locale(identifier: AppSettings.shared.config.localeIdentifier)
            do {
                try await AppleSpeech.ensureInstalled(locale: locale, model: .speech)
                try await AppleSpeech.ensureInstalled(locale: locale, model: .dictation)
                v = true
            } catch {
                v = false
            }
        case "apple_intelligence":
            v = Cleanup.appleAvailability == nil
        case let c where c.hasPrefix("model:"):
            // Installed open model; with MURMUR_E2E_INSTALL_MODELS=1, install it
            // through the same code path as the Settings "Download" button.
            guard let m = LocalModel(rawValue: String(c.dropFirst(6))) else { v = false; break }
            let store = LocalModelStore.shared
            if !LocalModelStore.isInstalled(m), ProcessInfo.processInfo.environment["MURMUR_E2E_INSTALL_MODELS"] == "1" {
                log("  installing \(m.label)…")
                let t0 = Date()
                store.install(m)
                var last = ""
                while case .installing(let p, let step) = store.state(m) {
                    let line = "\(Int(p * 100))% \(step)"
                    if line != last { log("    \(line)"); last = line }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                log("  install → \(store.state(m)) in \(Int(Date().timeIntervalSince(t0)))s")
            }
            v = LocalModelStore.isInstalled(m)
        default:
            v = true
        }
        capabilityCache[capability] = v
        return v
    }

    struct Result: Encodable {
        var name: String
        var passed: Bool
        var raw: String
        var final: String
        var seconds: Double
        var notes: [String]
    }

    @MainActor static func run() async {
        NSApp.setActivationPolicy(.regular)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let shots = outDir.appendingPathComponent("screenshots")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        AppSettings.shared.config = Config()
        AppSettings.shared.config.hasOnboarded = true
        AppSettings.shared.config.playSounds = false

        var results: [Result] = []
        var skipped: [String] = []
        let env: [String: Any] = [
            "accessibility": AXIsProcessTrusted(),
            "screen_capture": CGPreflightScreenCaptureAccess(),
            "apple_intelligence": Cleanup.appleAvailability ?? "available",
            "microphones": MicrophoneManager.shared.devices.map(\.name),
        ]
        log("environment: \(env)")
        Cleanup.prewarmApple()

        if let path = value("--cases") {
            do {
                let dec = JSONDecoder()
                dec.keyDecodingStrategy = .convertFromSnakeCase
                let cases = try dec.decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                for (i, c) in cases.enumerated() {
                    if let v = c.requiresEnv, ProcessInfo.processInfo.environment[v]?.isEmpty ?? true {
                        log("skip \(c.name) (set \(v))")
                        continue
                    }
                    var missing: [String] = []
                    for r in c.requires ?? [] where !(await has(r)) { missing.append(r) }
                    if !missing.isEmpty {
                        log("skip \(c.name) (unavailable here: \(missing.joined(separator: ", ")))")
                        skipped.append(c.name)
                        continue
                    }
                    results.append(await runCase(c, index: i, shots: shots))
                }
            } catch {
                results.append(Result(name: "load cases", passed: false, raw: "", final: "", seconds: 0, notes: ["\(error)"]))
            }
        }

        if let r = await labTest() { results.append(r) }
        if let r = await evalTest() { results.append(r) }
        results.append(settingsMutationTest())
        results.append(contentsOf: await microphoneTests())

        if args.contains("--screenshots") {
            await screenshots(to: shots)
        }

        let report: [String: Any] = [
            "environment": env,
            "results": results.map { r in
                ["name": r.name, "passed": r.passed, "raw": r.raw, "final": r.final,
                 "seconds": (r.seconds * 100).rounded() / 100, "notes": r.notes] as [String: Any]
            },
            "passed": results.filter(\.passed).count,
            "failed": results.filter { !$0.passed }.count,
            "skipped": skipped,
        ]
        // Never leave test keys behind in the Keychain.
        for acct in [Keychain.Account.openrouter, .customTranscribe, .customCleanup] { Keychain.set("", for: acct) }
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? data.write(to: outDir.appendingPathComponent("report.json"))
        print(String(decoding: data, as: UTF8.self))
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }

    // MARK: Pipeline cases

    @MainActor private static func runCase(_ c: Case, index: Int, shots: URL) async -> Result {
        log("case \(c.name)")
        var cfg = AppSettings.shared.config
        cfg.engine = c.engine ?? .apple
        cfg.appleModel = c.appleModel ?? .speech
        cfg.localModel = c.localModel ?? .parakeetV3
        cfg.vocabulary = c.vocabulary ?? []
        cfg.cleanupEnabled = c.cleanup != nil
        cfg.cleanupEngine = c.cleanup ?? .apple
        cfg.cleanupSendsAudio = c.cleanupSendsAudio ?? false
        cfg.cleanupStyle = c.style ?? ""
        cfg.cleanupUseCustomPrompt = c.customPrompt != nil
        cfg.cleanupCustomPrompt = c.customPrompt ?? ""
        if let u = c.customUrl { cfg.customTranscribeURL = u; cfg.customCleanupURL = u }
        if let m = c.model {
            cfg.openrouterTranscribeModel = m; cfg.openrouterCleanupModel = m
            cfg.customTranscribeModel = m; cfg.customCleanupModel = m
        }
        if let m = c.transcribeModel { cfg.openrouterTranscribeModel = m; cfg.customTranscribeModel = m }
        AppSettings.shared.config = cfg
        if c.mock == true, let base = ProcessInfo.processInfo.environment["MURMUR_E2E_MOCK_BASE"] {
            setenv("MURMUR_OPENROUTER_BASE", base, 1)
        } else {
            unsetenv("MURMUR_OPENROUTER_BASE")
        }
        for acct in [Keychain.Account.openrouter, .customTranscribe, .customCleanup] { Keychain.set(resolveEnv(c.apiKey ?? ""), for: acct) }

        var notes: [String] = []
        let target = c.insert == true ? await ExternalTarget.open() : nil
        if c.insert == true && target == nil { notes.append("could not open TextEdit") }
        NSPasteboard.general.clearContents()

        let start = Date()
        let casesDir = URL(fileURLWithPath: value("--cases") ?? ".").deletingLastPathComponent()
        let audioURL = c.audio.hasPrefix("/") ? URL(fileURLWithPath: c.audio) : casesDir.appendingPathComponent(c.audio)
        let src = FileSource(url: audioURL, realtime: true)
        let ctl = DictationController.shared
        ctl.begin(source: src)
        guard ctl.phase == .listening else {
            return Result(name: c.name, passed: false, raw: "", final: "", seconds: 0, notes: ["did not start: \(ctl.phase)"])
        }

        // Grab the live HUD for the first case, mid-utterance.
        if index == 0 {
            try? await Task.sleep(for: .seconds(1.6))
            snapshot(HUDController.shared.window, to: shots.appendingPathComponent("hud-live-listening.png"), backdrop: true)
        }
        await src.waitUntilDone()
        let stoppedAt = Date()
        // Safety: only send ⌘V if the test target really is frontmost.
        let targetFocused = target?.isFrontmost ?? false
        if target != nil && !targetFocused { notes.append("TextEdit not frontmost (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")) — paste suppressed") }
        let task = ctl.stop(insert: targetFocused || (c.insert == true && !AXIsProcessTrusted()))
        if index == 0 {
            try? await Task.sleep(for: .milliseconds(120))
            snapshot(HUDController.shared.window, to: shots.appendingPathComponent("hud-live-processing.png"), backdrop: true)
        }
        let entry = await task?.value
        let elapsed = Date().timeIntervalSince(stoppedAt)
        _ = start
        let final = entry?.finalText ?? ""
        if let err = entry?.error { notes.append(err) }

        let expectsError = c.expectContains == ["__expect_error__"]
        var passed = expectsError ? (final.isEmpty && entry?.error != nil) : !final.isEmpty
        for w in c.expectContains ?? [] where !expectsError && !final.localizedCaseInsensitiveContains(w) {
            passed = false
            notes.append("missing “\(w)”")
        }
        if c.cleanup != nil && !expectsError && entry?.cleanedText == nil {
            passed = false
            notes.append("cleanup did not run")
        }
        for w in c.expectNotContains ?? [] where final.localizedCaseInsensitiveContains(w) {
            passed = false
            notes.append("unexpected “\(w)”")
        }

        if c.insert == true && !AXIsProcessTrusted() {
            // No Accessibility (e.g. CI): Murmur must fall back to the clipboard.
            let clip = NSPasteboard.general.string(forType: .string) ?? ""
            if !final.isEmpty && clip == final { notes.append("no Accessibility: copied-to-clipboard fallback ✓") }
            else { passed = false; notes.append("clipboard was “\(clip)”") }
            target?.close()
        } else if c.insert == true {
            if let target, targetFocused {
                try? await Task.sleep(for: .milliseconds(700))
                let typed = target.focusedText() ?? ""
                if !final.isEmpty && typed.contains(final) { notes.append("pasted into TextEdit ✓ (read back via Accessibility)") }
                else { passed = false; notes.append("TextEdit contained “\(typed)”") }
                let clip = NSPasteboard.general.string(forType: .string) ?? ""
                notes.append(clip.isEmpty ? "clipboard restored ✓" : "clipboard now “\(clip)”")
                target.screenshot(to: shots.appendingPathComponent("insert-textedit.png"))
            } else {
                passed = false
            }
            target?.close()
        }
        // Let the HUD finish its exit animation before the next case.
        try? await Task.sleep(for: .seconds(1.2))
        log("  → \(passed ? "PASS" : "FAIL") \(String(format: "%.2fs after release", elapsed)) “\(final)” \(notes)")
        return Result(name: c.name, passed: passed, raw: entry?.rawText ?? "", final: final, seconds: elapsed, notes: notes)
    }

    /// Regression: deleting a vocabulary term from Settings aborted the app with a
    /// Swift exclusivity violation, because the delete predicate read a SwiftUI
    /// Binding into `AppSettings.config` while `config` was being modified. Drive
    /// the same store helpers the panes use with exactly such predicates; a
    /// regression here kills the process (→ non-zero exit) rather than failing softly.
    @MainActor private static func settingsMutationTest() -> Result {
        let settings = AppSettings.shared
        let saved = settings.config
        defer { settings.config = saved }
        var notes: [String] = []
        var ok = true
        func check(_ cond: Bool, _ what: String) { if !cond { ok = false; notes.append("FAILED: \(what)") } }

        settings.config.vocabulary = [VocabTerm(term: "Alpha"), VocabTerm(term: "Beta", soundsLike: ["beater"]), VocabTerm(term: "Gamma")]
        let bindable = Bindable(settings)
        let row: Binding<VocabTerm> = bindable.config.vocabulary[1]
        settings.removeVocabulary { $0.id == row.wrappedValue.id }
        check(settings.config.vocabulary.map(\.term) == ["Alpha", "Gamma"], "vocabulary delete → \(settings.config.vocabulary.map(\.term))")
        notes.append("vocabulary delete with a binding-reading predicate ✓")

        settings.config.microphones = ["a", "b", "c", "d"].map { MicRecord(uid: $0, name: $0.uppercased()) }
        let mic: Binding<MicRecord> = bindable.config.microphones[0]
        settings.removeMicrophones { $0.uid == mic.wrappedValue.uid }
        check(settings.config.microphones.map(\.uid) == ["b", "c", "d"], "microphone forget → \(settings.config.microphones.map(\.uid))")
        settings.moveMicrophones(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        check(settings.config.microphones.map(\.uid) == ["c", "d", "b"], "move down → \(settings.config.microphones.map(\.uid))")
        settings.moveMicrophones(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        check(settings.config.microphones.map(\.uid) == ["b", "c", "d"], "move up → \(settings.config.microphones.map(\.uid))")
        var expected = settings.config.microphones
        expected.move(fromOffsets: IndexSet([0, 2]), toOffset: 2)
        settings.moveMicrophones(fromOffsets: IndexSet([0, 2]), toOffset: 2)
        check(settings.config.microphones == expected, "multi-move → \(settings.config.microphones.map(\.uid))")
        notes.append("microphone forget / reorder ✓")

        log("  → \(ok ? "PASS" : "FAIL") settings list edits: \(notes)")
        return Result(name: "settings · delete vocabulary term / forget & reorder microphones (exclusivity regression)",
                      passed: ok, raw: "", final: "", seconds: 0, notes: notes)
    }

    /// Priority resolution with the devices actually connected, then a real
    /// 1.5 s capture from each one.
    @MainActor private static func microphoneTests() async -> [Result] {
        var out: [Result] = []
        let mm = MicrophoneManager.shared
        mm.refresh()
        let devices = mm.devices
        let saved = AppSettings.shared.config.microphones

        if devices.count >= 2 {
            var notes: [String] = []
            var ok = true
            let recs = devices.map { MicRecord(uid: $0.uid, name: $0.name) }
            AppSettings.shared.config.microphones = recs
            ok = ok && mm.candidates().first?.uid == recs[0].uid
            notes.append("order A→ \(mm.candidates().first?.name ?? "-")")
            AppSettings.shared.config.microphones = recs.reversed()
            ok = ok && mm.candidates().first?.uid == recs.last!.uid
            notes.append("order B→ \(mm.candidates().first?.name ?? "-")")
            var disabled = Array(recs.reversed()); disabled[0].enabled = false
            AppSettings.shared.config.microphones = disabled
            ok = ok && mm.candidates().first?.uid == disabled[1].uid
            notes.append("top disabled→ \(mm.candidates().first?.name ?? "-")")
            var ghost = [MicRecord(uid: "disconnected-device", name: "Unplugged Mic")] + recs
            ghost[0].enabled = true
            AppSettings.shared.config.microphones = ghost
            ok = ok && mm.candidates().first?.uid == recs[0].uid
            notes.append("unplugged top→ \(mm.candidates().first?.name ?? "-")")
            log("  → \(ok ? "PASS" : "FAIL") mic priority: \(notes)")
            out.append(Result(name: "microphone priority resolution (\(devices.count) devices)", passed: ok, raw: "", final: "", seconds: 0, notes: notes))
        }
        AppSettings.shared.config.microphones = saved

        // Never block CI on a permission dialog nobody can click.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined && ProcessInfo.processInfo.environment["CI"] == nil {
            log("requesting microphone permission — click Allow")
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            log("skip real capture: microphone permission not granted")
            out.append(Result(name: "real microphone capture — skipped, no permission", passed: true, raw: "", final: "", seconds: 0, notes: []))
            return out
        }
        // Failover: find a device that opens but stays silent (virtual / remote
        // audio), put it first, and confirm dictation moves to a working mic.
        var silent: InputDevice?
        var working: InputDevice?
        for d in devices {
            let probe = MicrophoneSource(device: d)
            guard (try? probe.start(recordingTo: nil)) != nil else { continue }
            try? await Task.sleep(for: .milliseconds(700))
            if probe.hasReceivedAudio { working = working ?? d } else { silent = silent ?? d }
            _ = probe.stop()
        }
        if let silent, let working {
            AppSettings.shared.config.microphones = [MicRecord(uid: silent.uid, name: silent.name), MicRecord(uid: working.uid, name: working.name)]
            let ctl = DictationController.shared
            ctl.begin()
            try? await Task.sleep(for: .seconds(1.4))
            let using = ctl.microphoneName ?? "-"
            ctl.cancel(silently: true)
            AppSettings.shared.config.microphones = saved
            let ok = using == working.name
            log("  → \(ok ? "PASS" : "FAIL") failover: \(silent.name) first → dictation used \(using)")
            out.append(Result(name: "silent-device failover during dictation", passed: ok, raw: "", final: "", seconds: 0,
                              notes: ["priority: \(silent.name), \(working.name)", "used: \(using)"]))
        } else {
            log("skip failover test: needs one silent and one working input device")
        }

        for device in devices {
            let src = MicrophoneSource(device: device)
            let peak = PeakBox()
            src.onLevel = { peak.update($0) }
            let name = "real capture · \(device.name)"
            do {
                let safe = device.name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
                try src.start(recordingTo: outDir.appendingPathComponent("mic-\(safe).m4a"))
            } catch {
                out.append(Result(name: name, passed: false, raw: "", final: "", seconds: 0, notes: [error.localizedDescription]))
                continue
            }
            try? await Task.sleep(for: .seconds(1.5))
            let samples = src.stop()
            let secs = Double(samples.count) / 16_000
            let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
            // A device that opens but never delivers audio is legitimate (virtual/remote
            // devices); it's covered by the failover test, so report rather than fail.
            if secs == 0 {
                log("  → INFO \(name): opened but delivered no audio (handled by failover)")
                out.append(Result(name: name + " — no audio (virtual device)", passed: true, raw: "", final: "", seconds: 0, notes: ["no buffers"]))
                continue
            }
            let onCI = ProcessInfo.processInfo.environment["CI"] != nil
            let digitalSilence = rms == 0
            // Exact zeros from a real mic usually mean capture is blocked; CI's
            // virtual devices legitimately produce them.
            let ok = secs > 1.2 && secs < 1.9 && (!digitalSilence || onCI)
            let note = String(format: "captured %.2fs @16kHz, rms %.1f dBFS", secs, 20 * log10(max(rms, 1e-9)))
                + (digitalSilence ? (onCI ? " (digital silence — virtual CI device)" : " (all-zero samples — capture blocked?)") : " (non-zero samples ✓)")
            log("  → \(ok ? "PASS" : "FAIL") \(name): \(note)")
            out.append(Result(name: name, passed: ok, raw: "", final: "", seconds: secs, notes: [note]))
        }
        return out
    }

    // MARK: Lab

    /// Drive the Lab like a user: pick a recording, transcribe it with several
    /// engines, polish the result with a model × prompt grid, judge, rank.
    @MainActor private static func labTest() async -> Result? {
        guard let base = ProcessInfo.processInfo.environment["MURMUR_E2E_MOCK_BASE"] else { return nil }
        log("case Lab · replay, model × prompt grid, judge")
        HistoryStore.shared.reload()
        let lab = Lab.shared
        guard let entry = lab.entries.first(where: { !$0.rawText.isEmpty }) else {
            return Result(name: "Lab", passed: false, raw: "", final: "", seconds: 0, notes: ["no history entry with audio"])
        }
        setenv("MURMUR_OPENROUTER_BASE", base, 1)
        Keychain.set("test-key", for: .openrouter)
        AppSettings.shared.config.vocabulary = [VocabTerm(term: "Kubernetes", soundsLike: ["cooper netties"])]
        AppSettings.shared.config.cleanupStyle = "British spelling"
        AppSettings.shared.config.labPrompt = "CUSTOM-PROMPT terms={{terms}} style={{style}}"
        AppSettings.shared.config.labJudgeModel = "mock/judge"
        let t0 = Date()
        lab.select(entry.id)
        var stt: Set<Lab.STT> = [.openrouter("mock/audio-model")]
        if await has("apple_speech") { stt.insert(.apple(.speech)) }
        if LocalModelStore.isInstalled(.parakeetV3) { stt.insert(.local(.parakeetV3)) }
        lab.sttChoices = stt
        await lab.transcribe()
        var notes: [String] = []
        var ok = true
        for r in lab.sttResults {
            let good = r.status == .done && !r.text.isEmpty && r.seconds != nil
            ok = ok && good
            notes.append("stt \(r.title): \(good ? String(format: "%.2fs", r.seconds ?? 0) : "\(r.status)")")
        }
        if let pick = lab.sttResults.first(where: { $0.status == .done }) { lab.inputID = pick.id }
        lab.polishers = [.openrouter("mock/text-model"), .openrouter("mock/other-model")]
        lab.prompts = [.builtIn, .lab]
        lab.judge = true
        await lab.polish()
        let done = lab.cleanResults.filter { $0.status == .done }
        let grid = done.count == 4
        let judged = done.allSatisfy { $0.score != nil }
        let costed = done.allSatisfy { $0.usage?.cost != nil && $0.usage?.promptTokens != nil }
        let labPromptUsed = lab.cleanResults.filter { $0.detail == "Lab prompt" }.allSatisfy { $0.text.contains("custom prompt ok") }
        let ranked = lab.bestPick != nil
        ok = ok && grid && judged && costed && labPromptUsed && ranked
        notes.append("polish grid \(done.count)/4\(grid ? " ✓" : "")")
        notes.append("judge scores \(judged ? "✓" : "missing")")
        notes.append("usage/cost \(costed ? "✓" : "missing")")
        notes.append("lab prompt reached model \(labPromptUsed ? "✓" : "✗")")
        notes.append("best pick \(lab.bestPick.map { "\($0.title) · \($0.detail)" } ?? "none")")
        for r in lab.cleanResults where r.status != .done { notes.append("\(r.title): \(r.status)") }
        log("  → \(ok ? "PASS" : "FAIL") Lab: \(notes)")
        unsetenv("MURMUR_OPENROUTER_BASE")
        return Result(name: "Lab · replay, model × prompt grid, judge", passed: ok, raw: "", final: "",
                      seconds: Date().timeIntervalSince(t0), notes: notes)
    }

    /// Eval: every History recording × several pipelines, judged by a model
    /// that "listens", aggregated into a leaderboard; second run hits the cache.
    @MainActor private static func evalTest() async -> Result? {
        guard let base = ProcessInfo.processInfo.environment["MURMUR_E2E_MOCK_BASE"] else { return nil }
        log("case Lab Eval · all recordings × pipelines, listening judge, leaderboard")
        setenv("MURMUR_OPENROUTER_BASE", base, 1)
        defer { unsetenv("MURMUR_OPENROUTER_BASE") }
        Keychain.set("test-key", for: .openrouter)
        AppSettings.shared.config.labListenJudgeModel = "mock/judge"
        HistoryStore.shared.reload()
        let ev = LabEval.shared
        ev.excluded = []
        let recs = Array(ev.recordings.prefix(3))
        ev.excluded = Set(ev.recordings.map(\.id)).subtracting(recs.map(\.id))
        ev.sttChoices = [.openrouter("mock/audio-model")]
        if LocalModelStore.isInstalled(.parakeetV3) { ev.sttChoices.insert(.local(.parakeetV3)) }
        ev.polishers = [.openrouter("mock/text-model"), .openrouter("mock/other-model")]
        ev.prompts = [.builtIn]
        ev.includeRaw = true
        ev.judge = true
        ev.judgeListens = true
        let t0 = Date()
        ev.start()
        while ev.running { try? await Task.sleep(for: .milliseconds(100)) }
        let first = Date().timeIntervalSince(t0)
        var notes: [String] = []
        guard let run = ev.current else {
            return Result(name: "Lab Eval", passed: false, raw: "", final: "", seconds: first, notes: ["no run"])
        }
        let expected = recs.count * ev.pipelines.count
        let complete = run.cells.count == expected && run.cells.allSatisfy { $0.error == nil && $0.text != nil }
        let judged = run.cells.allSatisfy { $0.score != nil }
        let rows = ev.rows(run)
        let best = ev.best(run)
        let persisted = ev.runs.contains { $0.id == run.id }
        let csvLines = ev.csv(run).split(separator: "\n").count
        // Second run: transcripts come from the cache.
        let t1 = Date()
        ev.start()
        while ev.running { try? await Task.sleep(for: .milliseconds(100)) }
        let cachedOK = (ev.current?.cells.filter { $0.sttSeconds != nil }.count ?? 0) == expected
        notes.append("\(recs.count) recordings × \(ev.pipelines.count) pipelines = \(run.cells.count)/\(expected) results\(complete ? " ✓" : "")")
        notes.append("listening judge scored all \(judged ? "✓" : "✗")")
        notes.append("leaderboard rows \(rows.count), best: \(best.map { LabEval.label($0.pipeline).stt + " → " + LabEval.label($0.pipeline).cleanup } ?? "none")")
        notes.append("run saved \(persisted ? "✓" : "✗"), CSV lines \(csvLines)")
        notes.append(String(format: "first run %.1fs, cached re-run %.1fs %@", first, Date().timeIntervalSince(t1), cachedOK ? "✓" : "✗"))
        for c in run.cells where c.error != nil { notes.append("error: \(c.error!)") }
        let ok = complete && judged && rows.count == ev.pipelines.count && best != nil && persisted && csvLines == expected + 1 && cachedOK
        log("  → \(ok ? "PASS" : "FAIL") Lab Eval: \(notes)")
        ev.excluded = []
        return Result(name: "Lab Eval · recordings × pipelines, judge, leaderboard", passed: ok, raw: "", final: "",
                      seconds: Date().timeIntervalSince(t0), notes: notes)
    }

    // MARK: Screenshots

    @MainActor private static func screenshots(to dir: URL) async {
        for (scheme, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            NSApp.appearance = appearance
            AppSettings.shared.config.cleanupEnabled = true
            AppSettings.shared.config.developerMode = true
            AppSettings.shared.config.engine = .local
            AppSettings.shared.config.localModel = .parakeetV3
            AppSettings.shared.config.vocabulary = [
                VocabTerm(term: "Kubernetes", soundsLike: ["cooper netties"]),
                VocabTerm(term: "JQ Reyes", soundsLike: ["jay queue reyes"]),
                VocabTerm(term: "OpenRouter"),
                VocabTerm(term: "SwiftUI", soundsLike: ["swift you eye"]),
            ]
            SettingsWindowController.shared.show(.home)
            SettingsWindowController.shared.window?.setContentSize(NSSize(width: 960, height: 700))
            SettingsWindowController.shared.window?.center()
            for pane in Pane.allCases {
                SettingsNavigation.shared.pane = pane
                try? await Task.sleep(for: .milliseconds(900))
                snapshot(SettingsWindowController.shared.window, to: dir.appendingPathComponent("\(scheme)-pane-\(pane.rawValue).png"))
            }
            // Custom cleanup prompt editor (below the fold: scroll the form to the end).
            AppSettings.shared.config.cleanupUseCustomPrompt = true
            AppSettings.shared.config.cleanupCustomPrompt = "You polish dictated text for {{app}}.\n\nRules:\n- Remove fillers and false starts.\n- Keep my wording.\n- Output only the cleaned text.{{vocabulary_section}}{{style_section}}"
            SettingsNavigation.shared.pane = .cleanup
            try? await Task.sleep(for: .milliseconds(900))
            if let root = SettingsWindowController.shared.window?.contentView {
                func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
                if let sv = scrollViews(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
                   let doc = sv.documentView {
                    let y = doc.isFlipped ? max(0, doc.frame.height - sv.contentView.bounds.height) - 140 : 140
                    sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                    sv.reflectScrolledClipView(sv.contentView)
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
            snapshot(SettingsWindowController.shared.window, to: dir.appendingPathComponent("\(scheme)-pane-cleanup-prompt.png"))
            // Lab eval leaderboard (bottom of the Lab pane).
            SettingsNavigation.shared.pane = .lab
            try? await Task.sleep(for: .milliseconds(900))
            if let root = SettingsWindowController.shared.window?.contentView {
                func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
                if let sv = scrollViews(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
                   let doc = sv.documentView {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? max(0, doc.frame.height - sv.contentView.bounds.height) : 0))
                    sv.reflectScrolledClipView(sv.contentView)
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
            snapshot(SettingsWindowController.shared.window, to: dir.appendingPathComponent("\(scheme)-pane-lab-results.png"))
            AppSettings.shared.config.cleanupUseCustomPrompt = false
            SettingsWindowController.shared.window?.orderOut(nil)

            let ctl = DictationController.shared
            let wave: [Float] = (0..<DictationController.barCount).map { (i: Int) -> Float in
                let x = Double(i)
                let swing: Double = abs(sin(x * 0.55))
                let envelope: Double = 0.6 + 0.4 * cos(x * 0.21)
                return Float(0.25 + 0.7 * swing * envelope)
            }
            let states: [(String, () -> Void)] = [
                ("listening", { ctl.debugSet(phase: .listening, partial: "Let's move the Kubernetes review to Wednesday and loop in", levels: wave) }),
                ("handsfree", { ctl.debugSet(phase: .listening, partial: "", levels: wave, latched: true) }),
                ("transcribing", { ctl.debugSet(phase: .processing("Transcribing"), partial: "Let's move the Kubernetes review to Wednesday.") }),
                ("polishing", { ctl.debugSet(phase: .processing("Polishing")) }),
                ("done", { ctl.debugSet(phase: .done("Let's move the Kubernetes review to Wednesday.")) }),
                ("copied-accessibility", { ctl.debugSet(phase: .copied(.noAccessibility)) }),
                ("copied-secure-input", { ctl.debugSet(phase: .copied(.secureInput(app: "iTerm2"))) }),
                ("error", { ctl.debugSet(phase: .error("Couldn't reach OpenRouter. Check your connection.")) }),
            ]
            for (name, apply) in states {
                apply()
                try? await Task.sleep(for: .milliseconds(700))
                snapshot(HUDController.shared.window, to: dir.appendingPathComponent("\(scheme)-hud-\(name).png"), backdrop: true)
            }
            ctl.debugSet(phase: .hidden)
            HUDController.shared.window?.orderOut(nil)
        }
        NSApp.appearance = nil
    }

    /// Real window capture when Screen Recording is granted; otherwise render
    /// the view hierarchy in-process (no permission needed, materials flatter).
    @MainActor @discardableResult
    static func snapshot(_ window: NSWindow?, to url: URL, backdrop: Bool = false) -> Bool {
        guard let window else { return false }
        if CGPreflightScreenCaptureAccess() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            if backdrop, let screen = window.screen {
                // Capture the screen region so translucent glass is shown over the real desktop.
                let f = window.frame
                let top = screen.frame.maxY - f.maxY
                p.arguments = ["-x", "-R", "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))", url.path]
            } else {
                p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
            }
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return true }
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        var image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        if backdrop {
            // Composite onto a desktop-like backdrop so translucent HUD states are legible.
            let composed = NSImage(size: view.bounds.size)
            composed.lockFocus()
            NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.42, alpha: 1),
                                NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.62, alpha: 1),
                                NSColor(calibratedRed: 0.93, green: 0.62, blue: 0.52, alpha: 1)])?
                .draw(in: NSRect(origin: .zero, size: view.bounds.size), angle: -20)
            image.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            composed.unlockFocus()
            image = composed
        }
        guard let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// "$NAME" → value of environment variable NAME (keeps secrets out of fixtures).
    static func resolveEnv(_ s: String) -> String {
        guard s.hasPrefix("$") else { return s }
        return ProcessInfo.processInfo.environment[String(s.dropFirst())] ?? ""
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("[e2e] \(s)\n".utf8))
    }
}

/// A TextEdit document that dictation is pasted into during the insert test,
/// exercising the real cross-app path (focus stays in another app, ⌘V via CGEvent).
@MainActor
final class ExternalTarget {
    static let bundleID = "com.apple.TextEdit"
    let app: NSRunningApplication
    let file: URL
    let launchedByUs: Bool

    private init(app: NSRunningApplication, file: URL, launchedByUs: Bool) {
        self.app = app; self.file = file; self.launchedByUs = launchedByUs
    }

    static func open(rtf: Bool = false) async -> ExternalTarget? {
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("murmur-\(rtf ? "demo" : "e2e")-\(UUID().uuidString.prefix(6)).\(rtf ? "rtf" : "txt")")
        // The demo uses rich text so pasted dictation picks up large, legible type.
        let body = rtf ? #"{\rtf1\ansi\deff0{\fonttbl{\f0 HelveticaNeue;}}\pard\sl380\slmult1\f0\fs40 \par }"# : ""
        try? body.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "TextEdit", file.path]
        try? p.run()
        p.waitUntilExit()
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID {
                try? await Task.sleep(for: .milliseconds(400))
                return ExternalTarget(app: app, file: file, launchedByUs: !wasRunning)
            }
        }
        return nil
    }

    /// Move/resize the front document window (top-left-origin screen points).
    func setFrame(_ r: CGRect) {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return }
        var origin = r.origin
        var size = r.size
        if let pos = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w as! AXUIElement, kAXPositionAttribute as CFString, pos) }
        if let sz = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w as! AXUIElement, kAXSizeAttribute as CFString, sz) }
    }

    var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }

    func focusedText() -> String? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func screenshot(to url: URL) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let num = w[kCGWindowNumber as String] as? Int else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(num)", url.path]
        try? p.run()
        p.waitUntilExit()
    }

    func close() {
        if launchedByUs { app.forceTerminate() }
        try? FileManager.default.removeItem(at: file)
    }
}

final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Float = 0
    var value: Float { lock.lock(); defer { lock.unlock() }; return v }
    func update(_ x: Float) { lock.lock(); v = max(v, x); lock.unlock() }
}
