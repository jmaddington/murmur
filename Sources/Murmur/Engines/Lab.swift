@preconcurrency import AVFAudio
import Foundation

/// Developer-mode workbench: replay a saved recording through other speech
/// models, then through a grid of cleanup models × prompts, with timings,
/// token counts, cost and an optional judge score.
@MainActor @Observable
final class Lab {
    static let shared = Lab()

    enum Status: Equatable { case running, done, failed(String) }

    struct Usage: Decodable, Sendable, Equatable {
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
    }

    struct Result: Identifiable, Equatable {
        let id = UUID().uuidString
        var title: String
        var detail: String = ""
        var status: Status = .running
        var text = ""
        var seconds: Double?
        var usage: Usage?
        var score: Double?
        var notes: String?
        var judgeError: String?
    }

    /// A speech-to-text setup to try.
    enum STT: Hashable, Identifiable {
        case apple(AppleSpeechModel), local(LocalModel), openrouter(String), custom
        var id: String {
            switch self {
            case .apple(let m): "apple:\(m.rawValue)"
            case .local(let m): "local:\(m.rawValue)"
            case .openrouter(let m): "or:\(m)"
            case .custom: "custom"
            }
        }
        @MainActor var label: String {
            switch self {
            case .apple(let m): "Apple · \(m.label)"
            case .local(let m): m.label
            case .openrouter(let m): m
            case .custom: "Custom · \(AppSettings.shared.config.customTranscribeModel)"
            }
        }
    }

    /// A cleanup model to try.
    enum Polisher: Hashable, Identifiable {
        case apple, openrouter(String), custom
        var id: String {
            switch self {
            case .apple: "apple"
            case .openrouter(let m): "or:\(m)"
            case .custom: "custom"
            }
        }
        @MainActor var label: String {
            switch self {
            case .apple: "Apple Intelligence"
            case .openrouter(let m): m
            case .custom: "Custom · \(AppSettings.shared.config.customCleanupModel)"
            }
        }
    }

    enum PromptChoice: String, CaseIterable, Identifiable {
        case builtIn, mine, lab
        var id: String { rawValue }
        var label: String {
            switch self {
            case .builtIn: "Built-in"
            case .mine: "My prompt"
            case .lab: "Lab prompt"
            }
        }
    }

    // Selection
    var entryID: String?
    var sttChoices: Set<STT> = [.apple(.speech)]
    var polishers: Set<Polisher> = []
    var prompts: Set<PromptChoice> = [.builtIn]
    var judge = true
    /// "original" or the id of a transcription result.
    var inputID = "original"

    // Results
    var sttResults: [Result] = []
    var cleanResults: [Result] = []
    var transcribing = false
    var polishing = false

    private var samplesCache: (id: String, samples: [Float])?

    private init() {}

    var entries: [HistoryEntry] { HistoryStore.shared.entries.filter { $0.audioPath != nil } }
    var entry: HistoryEntry? { entries.first { $0.id == entryID } ?? entries.first }

    func select(_ id: String) {
        guard id != entryID else { return }
        entryID = id
        sttResults = []
        cleanResults = []
        inputID = "original"
    }

    var inputText: String {
        if inputID != "original", let r = sttResults.first(where: { $0.id == inputID }), r.status == .done { return r.text }
        return entry?.rawText ?? ""
    }

    /// The fastest cleanup the judge rated 8+ (or, unjudged, simply the fastest).
    var bestPick: Result? {
        let done = cleanResults.filter { $0.status == .done && $0.seconds != nil }
        let judged = done.filter { $0.score != nil }
        let pool = judged.isEmpty ? done : judged.filter { ($0.score ?? 0) >= 8 }
        return pool.min { ($0.seconds ?? .infinity) < ($1.seconds ?? .infinity) }
    }

    // MARK: Audio

    private func samples(for e: HistoryEntry) async throws -> [Float] {
        if let c = samplesCache, c.id == e.id { return c.samples }
        guard let path = e.audioPath else { throw CaptureError(message: "This entry has no saved audio.") }
        let s = try await Task.detached(priority: .userInitiated) {
            try loadSpeechSamples(from: URL(fileURLWithPath: path))
        }.value
        samplesCache = (e.id, s)
        return s
    }

    // MARK: Transcribe

    func transcribe() async {
        guard let e = entry, !transcribing else { return }
        transcribing = true
        defer { transcribing = false }
        let order = sttChoices.sorted { $0.id < $1.id }
        sttResults = order.map { Result(title: $0.label) }
        if !sttResults.contains(where: { $0.id == inputID }) { inputID = "original" }
        let audio: [Float]
        do { audio = try await samples(for: e) } catch {
            for i in sttResults.indices { sttResults[i].status = .failed(error.localizedDescription) }
            return
        }
        // One at a time: local models share the GPU / Neural Engine and would
        // skew each other's timings.
        for (i, choice) in order.enumerated() {
            let cfg = pipeline(for: choice, appName: e.appName)
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let raw = try await Self.runSession(cfg.makeSession(), samples: audio, feedsBuffers: choice.isApple)
                sttResults[i].text = RustCore.applyVocabulary(raw, cfg.vocabulary)
                sttResults[i].seconds = (clock.now - start).seconds
                sttResults[i].status = .done
            } catch {
                sttResults[i].status = .failed(error.localizedDescription)
            }
        }
    }

    func pipelineConfig(for choice: STT, appName: String?) -> PipelineConfig { pipeline(for: choice, appName: appName) }

    private func pipeline(for choice: STT, appName: String?) -> PipelineConfig {
        var cfg = PipelineConfig.current(appName: appName)
        let c = AppSettings.shared.config
        switch choice {
        case .apple(let m):
            cfg.engine = .apple; cfg.appleModel = m
        case .local(let m):
            cfg.engine = .local; cfg.localModel = m
        case .openrouter(let m):
            cfg.engine = .openrouter
            cfg.transcribeProvider = RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: m)
        case .custom:
            cfg.engine = .openaiCompatible
            cfg.transcribeProvider = RemoteProvider(kind: .openaiCompatible, baseUrl: c.customTranscribeURL,
                                                    apiKey: Keychain.get(.customTranscribe), model: c.customTranscribeModel)
        }
        return cfg
    }

    /// Feed a recording through a session as if it were being spoken (Apple's
    /// analyzer needs buffers), then finish it.
    nonisolated static func runSession(_ session: TranscriptionSession, samples: [Float], feedsBuffers: Bool) async throws -> String {
        if feedsBuffers {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let chunk = 1_600
            var i = 0
            while i < samples.count {
                let n = min(chunk, samples.count - i)
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
                buf.frameLength = AVAudioFrameCount(n)
                samples.withUnsafeBufferPointer { src in
                    buf.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
                }
                session.append(buf)
                i += n
            }
        }
        defer { session.cancel() }
        return try await session.finish(samples: samples)
    }

    // MARK: Polish

    func polish() async {
        guard let e = entry, !polishing else { return }
        let input = inputText
        guard !input.isEmpty else { return }
        polishing = true
        defer { polishing = false }

        let c = AppSettings.shared.config
        let models = polishers.sorted { $0.id < $1.id }
        let promptList = PromptChoice.allCases.filter { prompts.contains($0) }
        var jobs: [(index: Int, polisher: Polisher, prompt: PromptChoice)] = []
        cleanResults = []
        for m in models {
            for p in promptList {
                cleanResults.append(Result(title: m.label, detail: p.label))
                jobs.append((cleanResults.count - 1, m, p))
            }
        }

        func config(_ m: Polisher, _ p: PromptChoice) -> PipelineConfig {
            cleanupConfig(m, p, appName: c.cleanupUsesAppContext ? e.appName : nil)
        }
        // Apple's on-device model runs one at a time; remote calls run together.
        let remote = jobs.filter { $0.polisher != .apple }
        let local = jobs.filter { $0.polisher == .apple }
        await withTaskGroup(of: Void.self) { group in
            for job in remote {
                let cfg = config(job.polisher, job.prompt)
                group.addTask { await self.runPolish(job.index, input: input, cfg: cfg) }
            }
            group.addTask {
                for job in local { await self.runPolish(job.index, input: input, cfg: config(job.polisher, job.prompt)) }
            }
        }
        if judge { await judgeAll(input: input) }
    }

    /// Cleanup settings for one Lab model × prompt choice.
    func cleanupConfig(_ m: Polisher, _ p: PromptChoice, appName: String?) -> PipelineConfig {
        let c = AppSettings.shared.config
        var cfg = PipelineConfig.current(appName: appName)
        cfg.cleanupEnabled = true
        cfg.cleanupSendsAudio = false
        switch m {
        case .apple:
            cfg.cleanupEngine = .apple
        case .openrouter(let model):
            cfg.cleanupEngine = .openrouter
            cfg.cleanupProvider = RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: model)
        case .custom:
            cfg.cleanupEngine = .openaiCompatible
            cfg.cleanupProvider = RemoteProvider(kind: .openaiCompatible, baseUrl: c.customCleanupURL,
                                                 apiKey: Keychain.get(.customCleanup), model: c.customCleanupModel)
        }
        switch p {
        case .builtIn: cfg.cleanupCustomPrompt = nil
        case .mine: cfg.cleanupCustomPrompt = c.cleanupCustomPrompt
        case .lab: cfg.cleanupCustomPrompt = c.labPrompt.isEmpty ? nil : c.labPrompt
        }
        return cfg
    }

    private func runPolish(_ index: Int, input: String, cfg: PipelineConfig) async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (text, usage) = try await Self.polishDetailed(input, cfg: cfg)
            cleanResults[index].seconds = (clock.now - start).seconds
            cleanResults[index].text = RustCore.applyVocabulary(text, cfg.vocabulary)
            cleanResults[index].usage = usage
            cleanResults[index].status = .done
        } catch {
            cleanResults[index].status = .failed(error.localizedDescription)
        }
    }

    /// Like `Cleanup.run`, but also returns token usage / cost for remote models.
    nonisolated static func polishDetailed(_ text: String, cfg: PipelineConfig) async throws -> (String, Usage?) {
        guard cfg.cleanupEngine != .apple, let provider = cfg.cleanupProvider else {
            return (try await Cleanup.run(text, config: cfg, samples: []), nil)
        }
        struct A: Encodable, Sendable { let provider: RemoteProvider; let text: String; let context: RustCore.PromptContext; let wavPath: String? }
        struct R: Decodable, Sendable { let text: String; let usage: Usage? }
        let r = try await RustCore.callAsync(
            "cleanup", A(provider: provider, text: text, context: cfg.promptContext(withAudio: false), wavPath: nil), as: R.self)
        return (r.text, r.usage)
    }

    private func judgeAll(input: String) async {
        let c = AppSettings.shared.config
        let provider = RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: c.labJudgeModel)
        let vocab = c.vocabulary
        struct A: Encodable, Sendable { let provider: RemoteProvider; let transcript: String; let candidate: String; let vocabulary: [VocabTerm] }
        struct R: Decodable, Sendable { let score: Double; let notes: String }
        await withTaskGroup(of: (Int, Result).self) { group in
            for (i, r) in cleanResults.enumerated() where r.status == .done {
                group.addTask {
                    var out = r
                    do {
                        let v = try await RustCore.callAsync("judge", A(provider: provider, transcript: input, candidate: r.text, vocabulary: vocab), as: R.self)
                        out.score = v.score
                        out.notes = v.notes
                    } catch {
                        out.judgeError = error.localizedDescription
                    }
                    return (i, out)
                }
            }
            for await (i, r) in group where cleanResults.indices.contains(i) {
                cleanResults[i].score = r.score
                cleanResults[i].notes = r.notes
                cleanResults[i].judgeError = r.judgeError
            }
        }
    }
}

private extension Lab.STT {
    var isApple: Bool { if case .apple = self { true } else { false } }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
