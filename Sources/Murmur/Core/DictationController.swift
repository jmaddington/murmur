import AVFoundation
import AppKit
import Observation

enum HUDPhase: Equatable {
    case hidden
    case listening
    case processing(String)
    case done(String)
    case copied
    case error(String)
}

/// The dictation state machine: trigger → capture → transcribe → vocabulary →
/// cleanup → insert → history.
@MainActor @Observable
final class DictationController {
    static let shared = DictationController()

    private(set) var phase: HUDPhase = .hidden
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.barCount)
    private(set) var partial = ""
    private(set) var latched = false
    private(set) var startedAt: Date?
    private(set) var microphoneName: String?
    /// Pipeline is mid-flight (not cancellable from the trigger).
    private(set) var busy = false

    static let barCount = 26
    private static let tapThreshold: TimeInterval = 0.32
    private static let maxDuration: TimeInterval = 15 * 60

    private var source: AudioSource?
    private var session: TranscriptionSession?
    private var config: PipelineConfig?
    private var entryID = ""
    private var audioURL: URL?
    private var pressedAt = Date.distantPast
    private var hideTask: Task<Void, Never>?
    private var maxTimer: Task<Void, Never>?
    private var smoothed: Float = 0

    // MARK: Trigger handling

    func install() {
        let hk = HotkeyManager.shared
        hk.onPress = { [weak self] in self?.triggerDown() }
        hk.onRelease = { [weak self] in self?.triggerUp() }
        hk.onChord = { [weak self] in self?.chord() }
        hk.onEscape = { [weak self] in self?.escape() }
        hk.install()
    }

    private func triggerDown() {
        switch phase {
        case .listening where latched: stop()
        case .listening: break
        default:
            guard !busy else { return }
            pressedAt = Date()
            begin()
        }
    }

    private func triggerUp() {
        guard phase == .listening, !latched else { return }
        if Date().timeIntervalSince(pressedAt) < Self.tapThreshold {
            latched = true // quick tap → hands-free until the next tap
        } else {
            stop()
        }
    }

    private func chord() {
        // fn+arrow, ⌥+letter etc. — the user wasn't trying to dictate.
        if phase == .listening, !latched, Date().timeIntervalSince(pressedAt) < 1.5 { cancel(silently: true) }
    }

    private func escape() {
        if phase == .listening { cancel(silently: false) }
    }

    func toggleFromMenu() {
        if phase == .listening { stop() } else if !busy { latched = true; begin() }
    }

    // MARK: Capture

    func begin(source injected: AudioSource? = nil) {
        hideTask?.cancel()
        if injected == nil {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                return
            default:
                show(.error("Microphone access is off. Enable it in System Settings › Privacy."), hideAfter: 4)
                return
            }
        }

        let appName = NSWorkspace.shared.frontmostApplication.flatMap { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app.localizedName
        }
        let cfg = PipelineConfig.current(appName: appName)
        if cfg.engine != .apple, cfg.transcribeProvider?.kind == .openrouter, (cfg.transcribeProvider?.apiKey ?? "").isEmpty {
            show(.error("Add an OpenRouter API key in Settings › Transcription."), hideAfter: 4)
            return
        }
        config = cfg
        entryID = UUID().uuidString
        audioURL = HistoryStore.shared.audioURL(for: entryID)
        partial = ""
        levels = Array(repeating: 0, count: Self.barCount)
        smoothed = 0

        let session = cfg.makeSession()
        session.onPartial = { [weak self] text in
            guard let self, self.phase == .listening || self.phase == .processing("Transcribing") else { return }
            self.partial = text
        }
        self.session = session

        pendingCandidates = injected.map { [$0] }
            ?? MicrophoneManager.shared.candidates().map { MicrophoneSource(device: $0) }
        var lastError: Error?
        let started = startNextSource(session: session, lastError: &lastError)
        guard let started else {
            session.cancel()
            show(.error(lastError?.localizedDescription ?? "No microphone available."), hideAfter: 3)
            return
        }
        source = started
        microphoneName = started.deviceName
        if injected == nil { watchForSilentDevice(started) }
        startedAt = Date()
        if injected != nil { latched = true }
        phase = .listening
        HUDController.shared.present()
        Sound.play(.start)

        maxTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxDuration))
            if !Task.isCancelled { self?.stop() }
        }
    }

    private var pendingCandidates: [AudioSource] = []

    /// Starts the first remaining candidate that opens successfully.
    private func startNextSource(session: TranscriptionSession, lastError: inout Error?) -> AudioSource? {
        while !pendingCandidates.isEmpty {
            let src = pendingCandidates.removeFirst()
            src.onBuffer = { [weak session] buf in session?.append(buf) }
            src.onLevel = { [weak self] level in
                Task { @MainActor in self?.push(level: level) }
            }
            src.onFailure = { [weak self] err in
                Task { @MainActor in self?.sourceFailed(err) }
            }
            do {
                try src.start(recordingTo: audioURL)
                return src
            } catch {
                lastError = error
                NSLog("Murmur: \(src.deviceName ?? "mic") failed: \(error.localizedDescription) — trying next")
            }
        }
        return nil
    }

    /// Some devices (virtual/remote audio, sleeping Bluetooth) open fine but
    /// never deliver audio. If nothing arrives quickly, fail over to the next
    /// microphone in priority order without interrupting the dictation.
    private func watchForSilentDevice(_ src: AudioSource) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.phase == .listening, self.source === src, !src.hasReceivedAudio,
                  let session = self.session else { return }
            NSLog("Murmur: \(src.deviceName ?? "mic") delivered no audio — failing over")
            _ = src.stop()
            var err: Error?
            guard let next = self.startNextSource(session: session, lastError: &err) else {
                self.cancel(silently: true)
                self.show(.error("\(src.deviceName ?? "Microphone") isn't sending audio."), hideAfter: 3)
                return
            }
            self.source = next
            self.microphoneName = next.deviceName
            self.watchForSilentDevice(next)
        }
    }

    private func push(level: Float) {
        guard phase == .listening else { return }
        // Fast attack, slower release reads as "alive" without jitter.
        smoothed = level > smoothed ? level : smoothed * 0.6 + level * 0.4
        levels.removeFirst()
        levels.append(smoothed)
    }

    private func sourceFailed(_ error: Error) {
        guard phase == .listening else { return }
        NSLog("Murmur: capture failed mid-recording: \(error.localizedDescription)")
        stop() // keep what we have rather than losing it
    }

    func cancel(silently: Bool) {
        maxTimer?.cancel()
        _ = source?.stop()
        session?.cancel()
        source = nil
        session = nil
        latched = false
        if let audioURL { try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent()) }
        if silently { phase = .hidden; HUDController.shared.dismiss() } else { show(.error("Cancelled"), hideAfter: 0.8) }
    }

    // MARK: Pipeline

    @discardableResult
    func stop(insert: Bool = true) -> Task<HistoryEntry?, Never>? {
        guard phase == .listening, let source, let session, let config else { return nil }
        maxTimer?.cancel()
        let samples = source.stop()
        let duration = Double(samples.count) / 16_000
        self.source = nil
        latched = false
        Sound.play(.stop)

        if duration < 0.3 {
            cancel(silently: true)
            return nil
        }

        busy = true
        phase = .processing("Transcribing")
        let id = entryID
        let audioURL = self.audioURL
        let mic = microphoneName

        return Task { [weak self] in
            guard let self else { return nil }
            defer { self.busy = false; self.session = nil }
            var entry = HistoryEntry(id: id, createdAt: (self.startedAt ?? Date()).timeIntervalSince1970,
                                     duration: duration, engine: config.engineLabel, appName: config.appName,
                                     microphone: mic)
            entry.audioPath = (audioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) ? audioURL?.path : nil
            do {
                let raw = try await session.finish(samples: samples)
                entry.rawText = raw
                var text = RustCore.applyVocabulary(raw, config.vocabulary)
                if config.cleanupEnabled, !text.isEmpty {
                    self.phase = .processing("Polishing")
                    do {
                        let cleaned = try await Cleanup.run(text, config: config, samples: samples)
                        text = RustCore.applyVocabulary(cleaned, config.vocabulary)
                        entry.cleanedText = text
                        entry.cleanupEngine = config.cleanupLabel
                    } catch {
                        entry.error = "Cleanup failed: \(error.localizedDescription)"
                        NSLog("Murmur: \(entry.error!)")
                    }
                }
                entry.finalText = text
                guard !text.isEmpty else {
                    entry.error = entry.error ?? "No speech detected"
                    HistoryStore.shared.save(entry)
                    self.show(.error("No speech detected"), hideAfter: 1.6)
                    return entry
                }
                HistoryStore.shared.save(entry)
                if insert {
                    let outcome = await TextInserter.insert(text, restoreClipboard: AppSettings.shared.config.restoreClipboard)
                    self.show(outcome == .pasted ? .done(text) : .copied, hideAfter: outcome == .pasted ? 0.9 : 2.2)
                } else {
                    self.show(.done(text), hideAfter: 0.9)
                }
                return entry
            } catch {
                entry.error = error.localizedDescription
                HistoryStore.shared.save(entry)
                self.show(.error(error.localizedDescription), hideAfter: 4)
                Sound.play(.error)
                return entry
            }
        }
    }

    /// Re-run a stored recording through the current pipeline (History › Retry).
    func retranscribe(_ entry: HistoryEntry) async -> String? {
        guard let path = entry.audioPath else { return nil }
        let cfg = PipelineConfig.current(appName: entry.appName)
        do {
            let samples = try await Task.detached { try loadSpeechSamples(from: URL(fileURLWithPath: path)) }.value
            let session = cfg.makeSession()
            let chunk = 1600
            var i = 0
            while i < samples.count {
                let n = min(chunk, samples.count - i)
                let buf = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(n))!
                buf.frameLength = AVAudioFrameCount(n)
                samples.withUnsafeBufferPointer { src in
                    buf.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
                }
                session.append(buf)
                i += n
            }
            var text = RustCore.applyVocabulary(try await session.finish(samples: samples), cfg.vocabulary)
            var updated = entry
            updated.rawText = text
            if cfg.cleanupEnabled, !text.isEmpty,
               let cleaned = try? await Cleanup.run(text, config: cfg, samples: samples) {
                text = RustCore.applyVocabulary(cleaned, cfg.vocabulary)
                updated.cleanedText = text
                updated.cleanupEngine = cfg.cleanupLabel
            }
            updated.finalText = text
            updated.engine = cfg.engineLabel
            updated.error = nil
            HistoryStore.shared.save(updated)
            return text
        } catch {
            return nil
        }
    }

    // MARK: HUD

    func show(_ p: HUDPhase, hideAfter: TimeInterval) {
        phase = p
        HUDController.shared.present()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hideAfter))
            guard !Task.isCancelled, let self, self.phase == p else { return }
            self.phase = .hidden
            HUDController.shared.dismiss()
        }
    }

    /// Test harness hook: force a HUD state for screenshots.
    func debugSet(phase p: HUDPhase, partial: String = "", levels: [Float]? = nil, latched: Bool = false) {
        hideTask?.cancel()
        phase = p
        self.partial = partial
        self.latched = latched
        if let levels { self.levels = levels }
        startedAt = Date().addingTimeInterval(-7)
        HUDController.shared.present()
    }
}

enum Sound {
    enum Kind { case start, stop, error }
    @MainActor static func play(_ k: Kind) {
        guard AppSettings.shared.config.playSounds else { return }
        let name: NSSound.Name = switch k {
        case .start: "Tink"
        case .stop: "Pop"
        case .error: "Basso"
        }
        guard let s = NSSound(named: name)?.copy() as? NSSound else { return }
        s.volume = k == .error ? 0.35 : 0.22
        s.play()
    }
}
