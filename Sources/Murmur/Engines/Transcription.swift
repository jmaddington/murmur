@preconcurrency import AVFAudio
import Foundation
import FoundationModels
import Speech

protocol TranscriptionSession: AnyObject {
    /// Live partial transcript (main thread). Remote engines never call it.
    var onPartial: ((String) -> Void)? { get set }
    var supportsLivePreview: Bool { get }
    /// 16 kHz mono buffers, any thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Called once capture has stopped, with every captured sample.
    func finish(samples: [Float]) async throws -> String
    func cancel()
}

/// Immutable snapshot of what a dictation needs, taken on the main actor.
struct PipelineConfig: Sendable {
    var engine: TranscriptionEngine
    var appleModel: AppleSpeechModel
    var localModel: LocalModel
    var locale: Locale
    var vocabulary: [VocabTerm]
    var transcribeProvider: RemoteProvider?
    var cleanupEnabled: Bool
    var cleanupEngine: CleanupEngine
    var cleanupProvider: RemoteProvider?
    var cleanupSendsAudio: Bool
    var cleanupStyle: String
    /// nil = built-in prompt.
    var cleanupCustomPrompt: String?
    var appName: String?

    @MainActor static func current(appName: String?) -> PipelineConfig {
        let c = AppSettings.shared.config
        let transcribe: RemoteProvider? = switch c.engine {
        case .apple, .local: nil
        case .openrouter: RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: c.openrouterTranscribeModel)
        case .openaiCompatible: RemoteProvider(kind: .openaiCompatible, baseUrl: c.customTranscribeURL, apiKey: Keychain.get(.customTranscribe), model: c.customTranscribeModel)
        }
        let cleanup: RemoteProvider? = switch c.cleanupEngine {
        case .apple: nil
        case .openrouter: RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: c.openrouterCleanupModel)
        case .openaiCompatible: RemoteProvider(kind: .openaiCompatible, baseUrl: c.customCleanupURL, apiKey: Keychain.get(.customCleanup), model: c.customCleanupModel)
        }
        return PipelineConfig(
            engine: c.engine, appleModel: c.appleModel, localModel: c.localModel, locale: Locale(identifier: c.localeIdentifier),
            vocabulary: c.vocabulary.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty },
            transcribeProvider: transcribe, cleanupEnabled: c.cleanupEnabled, cleanupEngine: c.cleanupEngine,
            cleanupProvider: cleanup, cleanupSendsAudio: c.cleanupSendsAudio, cleanupStyle: c.cleanupStyle,
            cleanupCustomPrompt: c.cleanupUseCustomPrompt ? c.cleanupCustomPrompt : nil,
            appName: c.cleanupUsesAppContext ? appName : nil)
    }

    func promptContext(withAudio: Bool, now: Date = .now) -> RustCore.PromptContext {
        RustCore.PromptContext(
            vocabulary: vocabulary, style: cleanupStyle, appName: appName, withAudio: withAudio,
            customPrompt: cleanupCustomPrompt,
            date: now.formatted(date: .complete, time: .omitted),
            time: now.formatted(date: .omitted, time: .shortened))
    }

    var engineLabel: String {
        switch engine {
        case .apple: "On-device (\(appleModel.label))"
        case .local: localModel.label
        case .openrouter, .openaiCompatible: "\(engine.label) · \(transcribeProvider?.model ?? "")"
        }
    }

    var cleanupLabel: String? {
        guard cleanupEnabled else { return nil }
        switch cleanupEngine {
        case .apple: return "Apple Intelligence"
        default: return "\(cleanupEngine.label) · \(cleanupProvider?.model ?? "")"
        }
    }

    func makeSession() -> TranscriptionSession {
        switch engine {
        case .apple: AppleSpeechSession(locale: locale, model: appleModel, vocabulary: vocabulary)
        case .local where localModel.runtime == .coreML: ParakeetSession(model: localModel)
        case .local: MLXSession(model: localModel)
        case .openrouter, .openaiCompatible: RemoteSession(provider: transcribeProvider!, vocabulary: vocabulary, locale: locale)
        }
    }
}

// MARK: - Apple on-device (SpeechAnalyzer)

enum AppleSpeechModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case speech, dictation
    var id: String { rawValue }
    var label: String { self == .speech ? "Speech" : "Dictation" }
    var detail: String {
        self == .speech
            ? "Apple's newest long-form model. Best accuracy."
            : "The classic dictation model, with strong custom-vocabulary biasing."
    }
}

enum AppleSpeech {
    enum State: Equatable { case checking, ready, needsDownload, downloading(Double), unsupported, failed(String) }

    static func module(for locale: Locale, model: AppleSpeechModel) async throws -> any SpeechModule {
        switch model {
        case .speech:
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                return try await module(for: locale, model: .dictation)
            }
            return SpeechTranscriber(locale: loc, preset: .progressiveTranscription)
        case .dictation:
            guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw CaptureError(message: "\(locale.identifier) isn't supported for on-device dictation")
            }
            return DictationTranscriber(locale: loc, contentHints: [], transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        }
    }

    /// Downloads the model if needed. `progress` is called on an arbitrary thread.
    static func ensureInstalled(locale: Locale, model: AppleSpeechModel, progress: ((Double) -> Void)? = nil) async throws {
        let m = try await module(for: locale, model: model)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [m]) {
            let obs = req.progress.observe(\.fractionCompleted) { p, _ in progress?(p.fractionCompleted) }
            defer { obs.invalidate() }
            try await req.downloadAndInstall()
        }
    }

    static func status(locale: Locale, model: AppleSpeechModel) async -> State {
        do {
            let m = try await module(for: locale, model: model)
            switch await AssetInventory.status(forModules: [m]) {
            case .installed: return .ready
            case .unsupported: return .unsupported
            default: return .needsDownload
            }
        } catch {
            return .unsupported
        }
    }

    static func supportedLocales() async -> [Locale] {
        let a = await SpeechTranscriber.supportedLocales
        let b = await DictationTranscriber.supportedLocales
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.identifier(.bcp47)).inserted }
            .sorted { $0.localizedString(forIdentifier: $0.identifier) ?? "" < $1.localizedString(forIdentifier: $1.identifier) ?? "" }
    }
}

final class AppleSpeechSession: TranscriptionSession, @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    let supportsLivePreview = true

    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var setupTask: Task<Void, Error>?
    // `resultsTask` and `cancelled` are shared between the setup task, the
    // audio thread and the main thread: only touch them while holding `lock`.
    private var resultsTask: Task<String, Error>?
    private var cancelled = false

    init(locale: Locale, model: AppleSpeechModel, vocabulary: [VocabTerm]) {
        // Capture starts immediately; audio queues in `pending` until the
        // analyzer is ready, so the first syllable is never lost.
        setupTask = Task.detached(priority: .userInitiated) { [weak self] in
            try await self?.setup(locale: locale, model: model, vocabulary: vocabulary.map(\.term))
        }
    }

    private func setup(locale: Locale, model: AppleSpeechModel, vocabulary: [String]) async throws {
        let module = try await AppleSpeech.module(for: locale, model: model)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if !vocabulary.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(ctx)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: speechFormat) else {
            throw CaptureError(message: "No audio format available for the speech model")
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task<String, Error>.detached { [weak self] in
            var finals: [String] = []
            func emit(_ volatile: String) {
                let text = Self.join(finals + [volatile])
                DispatchQueue.main.async { self?.onPartial?(text) }
            }
            if let m = module as? SpeechTranscriber {
                for try await r in m.results {
                    let t = String(r.text.characters)
                    if r.isFinal { finals.append(t); emit("") } else { emit(t) }
                }
            } else if let m = module as? DictationTranscriber {
                for try await r in m.results {
                    let t = String(r.text.characters)
                    if r.isFinal { finals.append(t); emit("") } else { emit(t) }
                }
            }
            return Self.join(finals)
        }
        // Cancelled while we were still setting up: `cancel()` had no analyzer
        // or results task to stop yet, so tear them down here.
        func abandon() async throws -> Never {
            cont.finish()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        let cancelledEarly = lock.withLock { () -> Bool in
            if cancelled { return true }
            resultsTask = results
            return false
        }
        if cancelledEarly { try await abandon() }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            cont.finish()
            results.cancel()
            throw error
        }

        let cancelledLate = lock.withLock { () -> Bool in
            if cancelled { return true }
            self.analyzer = analyzer
            self.analyzerFormat = format
            if format != speechFormat { converter = AVAudioConverter(from: speechFormat, to: format) }
            continuation = cont
            // Flush the queued audio *before* releasing the lock. Once
            // `continuation` is visible, `append` (audio thread) feeds the
            // analyzer directly; flushing after unlocking let a live buffer
            // overtake the backlog and reach the recognizer out of order.
            let backlog = pending
            pending.removeAll()
            backlog.forEach(pushLocked)
            return false
        }
        if cancelledLate { try await abandon() }
    }

    private static func join(_ parts: [String]) -> String {
        parts.reduce(into: "") { acc, p in
            let p = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return }
            acc += acc.isEmpty ? p : " " + p
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !cancelled else { return }
            if continuation == nil { pending.append(buffer) } else { pushLocked(buffer) }
        }
    }

    /// Converts if needed and feeds the analyzer. Caller must hold `lock`.
    private func pushLocked(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
        if let converter, let fmt = analyzerFormat {
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * fmt.sampleRate / buffer.format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if err == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        } else {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func finish(samples: [Float]) async throws -> String {
        try await setupTask?.value
        let (analyzer, results) = lock.withLock { () -> (SpeechAnalyzer?, Task<String, Error>?) in
            continuation?.finish()
            return (self.analyzer, resultsTask)
        }
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        return try await results?.value ?? ""
    }

    func cancel() {
        let (analyzer, results) = lock.withLock { () -> (SpeechAnalyzer?, Task<String, Error>?) in
            cancelled = true
            pending.removeAll()
            continuation?.finish()
            return (self.analyzer, resultsTask)
        }
        setupTask?.cancel()
        results?.cancel()
        Task { await analyzer?.cancelAndFinishNow() }
    }
}

// MARK: - Remote (OpenRouter / OpenAI-compatible) via Rust core

final class RemoteSession: TranscriptionSession {
    var onPartial: ((String) -> Void)?
    let supportsLivePreview = false
    let provider: RemoteProvider
    let vocabulary: [VocabTerm]
    let locale: Locale

    init(provider: RemoteProvider, vocabulary: [VocabTerm], locale: Locale) {
        self.provider = provider
        self.vocabulary = vocabulary
        self.locale = locale
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).wav")
        try RustCore.writeWAV(samples, sampleRate: 16_000, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        struct A: Encodable, Sendable { let provider: RemoteProvider; let wavPath: String; let vocabulary: [VocabTerm]; let language: String }
        return try await RustCore.callAsync(
            "transcribe",
            A(provider: provider, wavPath: wav.path, vocabulary: vocabulary, language: locale.identifier(.bcp47)),
            as: RustCore.TextResult.self
        ).text
    }

    func cancel() {}
}

// MARK: - Cleanup

enum Cleanup {
    static var appleAvailability: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading."
        case .unavailable: return "Apple Intelligence is unavailable."
        }
    }

    /// Load the on-device LLM ahead of the first dictation.
    @MainActor static func prewarmApple() {
        guard appleAvailability == nil else { return }
        LanguageModelSession(instructions: "Clean up dictated text.").prewarm()
    }

    static func run(_ text: String, config: PipelineConfig, samples: [Float]) async throws -> String {
        switch config.cleanupEngine {
        case .apple:
            if let why = appleAvailability { throw CaptureError(message: why) }
            let system = RustCore.cleanupSystemPrompt(config.promptContext(withAudio: false))
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(
                to: RustCore.cleanupUserPrompt(text),
                options: GenerationOptions(temperature: 0))
            let out = RustCore.sanitize(response.content)
            return out.isEmpty ? text : out
        case .openrouter, .openaiCompatible:
            guard let provider = config.cleanupProvider else { return text }
            var wavPath: String?
            if config.cleanupSendsAudio && config.cleanupEngine == .openrouter && !samples.isEmpty {
                let wav = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-clean-\(UUID().uuidString).wav")
                try RustCore.writeWAV(samples, sampleRate: 16_000, to: wav)
                wavPath = wav.path
            }
            defer { if let wavPath { try? FileManager.default.removeItem(atPath: wavPath) } }
            struct A: Encodable, Sendable { let provider: RemoteProvider; let text: String; let context: RustCore.PromptContext; let wavPath: String? }
            return try await RustCore.callAsync(
                "cleanup",
                A(provider: provider, text: text,
                  context: config.promptContext(withAudio: wavPath != nil),
                  wavPath: wavPath),
                as: RustCore.TextResult.self
            ).text
        }
    }
}
