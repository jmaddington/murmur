import Foundation

/// One way of turning audio into text: speech engine, then optional cleanup.
struct EvalPipeline: Codable, Hashable, Identifiable, Sendable {
    var stt: String
    var polisher: String?
    var prompt: String?

    var id: String { [stt, polisher ?? "-", prompt ?? "-"].joined(separator: "|") }
}

struct EvalCell: Codable, Identifiable, Sendable {
    var recordingID: String
    var pipelineID: String
    var sttText: String?
    var sttSeconds: Double?
    var text: String?
    var cleanSeconds: Double?
    var cost: Double?
    var score: Double?
    var notes: String?
    var error: String?
    var id: String { recordingID + "#" + pipelineID }
    var totalSeconds: Double? { sttSeconds.map { $0 + (cleanSeconds ?? 0) } }
}

struct EvalRun: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var createdAt = Date().timeIntervalSince1970
    var recordingIDs: [String]
    var pipelines: [EvalPipeline]
    var judgeModel: String?
    var judgeListens: Bool
    var cells: [EvalCell] = []

    var date: Date { Date(timeIntervalSince1970: createdAt) }
}

/// Averages for one pipeline across a run.
struct EvalRow: Identifiable {
    var pipeline: EvalPipeline
    var n: Int
    var failures: Int
    var score: Double?
    var sttSeconds: Double?
    var cleanSeconds: Double?
    var costPer1k: Double?
    var id: String { pipeline.id }
    var totalSeconds: Double? { sttSeconds.map { $0 + (cleanSeconds ?? 0) } }
}

extension Lab.STT {
    init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "apple": guard let m = AppleSpeechModel(rawValue: parts.last ?? "") else { return nil }; self = .apple(m)
        case "local": guard let m = LocalModel(rawValue: parts.last ?? "") else { return nil }; self = .local(m)
        case "or": guard parts.count == 2 else { return nil }; self = .openrouter(parts[1])
        case "custom": self = .custom
        default: return nil
        }
    }
}

extension Lab.Polisher {
    init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "apple": self = .apple
        case "or": guard parts.count == 2 else { return nil }; self = .openrouter(parts[1])
        case "custom": self = .custom
        default: return nil
        }
    }
}

// MARK: - Eval

@MainActor @Observable
final class LabEval {
    static let shared = LabEval()

    private(set) var runs: [EvalRun] = []
    var current: EvalRun?
    /// History entries left out of the next run (everything else is in).
    var excluded: Set<String> = []

    // Pipeline choices
    var sttChoices: Set<Lab.STT> = [.apple(.speech)]
    var polishers: Set<Lab.Polisher> = []
    var includeRaw = true
    var prompts: Set<Lab.PromptChoice> = [.builtIn]
    var judge = true
    var judgeListens = true

    // Progress
    private(set) var running = false
    private(set) var done = 0
    private(set) var total = 0
    private var task: Task<Void, Never>?

    let root: URL
    private var runsDir: URL { root.appendingPathComponent("Runs", isDirectory: true) }
    private var cacheURL: URL { root.appendingPathComponent("stt-cache.json") }
    /// "recording|stt" → raw transcript (before vocabulary) and seconds.
    private var sttCache: [String: CachedSTT] = [:]
    struct CachedSTT: Codable { var text: String; var seconds: Double }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = E2E.isActive ? E2E.outDir.appendingPathComponent("lab", isDirectory: true)
                            : base.appendingPathComponent("Murmur/Lab", isDirectory: true)
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let dec = JSONDecoder()
        let fm = FileManager.default
        runs = ((try? fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(EvalRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
        sttCache = (try? dec.decode([String: CachedSTT].self, from: Data(contentsOf: cacheURL))) ?? [:]
        if current == nil { current = runs.first }
    }

    /// Your History recordings that still have audio.
    var recordings: [HistoryEntry] { HistoryStore.shared.entries.filter { $0.audioPath != nil } }
    var selected: [HistoryEntry] { recordings.filter { !excluded.contains($0.id) } }

    func deleteRun(_ run: EvalRun) {
        try? FileManager.default.removeItem(at: runsDir.appendingPathComponent(run.id + ".json"))
        if current?.id == run.id { current = nil }
        reload()
    }

    // MARK: Pipelines

    var pipelines: [EvalPipeline] {
        let stts = sttChoices.map(\.id).sorted()
        var cleanups: [(String?, String?)] = includeRaw ? [(nil, nil)] : []
        for p in polishers.map(\.id).sorted() {
            for pr in Lab.PromptChoice.allCases where prompts.contains(pr) { cleanups.append((p, pr.rawValue)) }
        }
        return stts.flatMap { s in cleanups.map { EvalPipeline(stt: s, polisher: $0.0, prompt: $0.1) } }
    }

    // MARK: Run

    func start() {
        guard !running else { return }
        let recs = selected
        let pipes = pipelines
        guard !recs.isEmpty, !pipes.isEmpty else { return }
        let c = AppSettings.shared.config
        var run = EvalRun(recordingIDs: recs.map(\.id), pipelines: pipes,
                          judgeModel: judge ? (judgeListens ? c.labListenJudgeModel : c.labJudgeModel) : nil,
                          judgeListens: judgeListens)
        run.cells = []
        current = run
        running = true
        done = 0
        total = recs.count * pipes.count
        task = Task { await execute(recs) }
    }

    func cancel() { task?.cancel() }

    private func execute(_ recs: [HistoryEntry]) async {
        defer {
            running = false
            if let current { save(current) }
            reload()
        }
        guard var run = current else { return }
        let sttIDs = Array(Set(run.pipelines.map(\.stt))).sorted()
        for rec in recs {
            if Task.isCancelled { break }
            let audio: [Float]
            do {
                let path = rec.audioPath ?? ""
                audio = try await Task.detached(priority: .userInitiated) { try loadSpeechSamples(from: URL(fileURLWithPath: path)) }.value
            } catch {
                for p in run.pipelines { run.cells.append(EvalCell(recordingID: rec.id, pipelineID: p.id, error: error.localizedDescription)) }
                done += run.pipelines.count; current = run
                continue
            }
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-eval-\(UUID().uuidString).wav")
            try? RustCore.writeWAV(audio, sampleRate: 16_000, to: wav)
            defer { try? FileManager.default.removeItem(at: wav) }

            // 1. Speech engines, one at a time (cached across runs).
            var stt: [String: Result<CachedSTT, Error>] = [:]
            for id in sttIDs {
                if Task.isCancelled { break }
                stt[id] = await transcribe(rec, sttID: id, audio: audio)
            }

            // 2. Cleanups for this recording: remote in parallel, Apple serially.
            var cells: [EvalCell] = []
            var jobs: [(Int, EvalPipeline, String)] = []
            for p in run.pipelines {
                var cell = EvalCell(recordingID: rec.id, pipelineID: p.id)
                switch stt[p.stt] {
                case .success(let s)?:
                    let vocab = AppSettings.shared.config.vocabulary
                    cell.sttText = RustCore.applyVocabulary(s.text, vocab)
                    cell.sttSeconds = s.seconds
                    if p.polisher == nil { cell.text = cell.sttText } else { jobs.append((cells.count, p, cell.sttText ?? "")) }
                case .failure(let e)?: cell.error = "Transcription: \(e.localizedDescription)"
                case nil: cell.error = "Cancelled"
                }
                cells.append(cell)
            }
            let polished = await polishAll(jobs, appName: rec.appName)
            for (i, r) in polished {
                switch r {
                case .success(let (text, secs, cost)): cells[i].text = text; cells[i].cleanSeconds = secs; cells[i].cost = cost
                case .failure(let e): cells[i].error = "Cleanup: \(e.localizedDescription)"
                }
            }

            // 3. Judge every finished result.
            if let model = run.judgeModel, !Task.isCancelled {
                let verdicts = await judgeAll(cells, model: model, listens: run.judgeListens, wav: wav)
                for (i, v) in verdicts {
                    switch v {
                    case .success(let (score, notes)): cells[i].score = score; cells[i].notes = notes
                    case .failure(let e): cells[i].notes = "Judge failed: \(e.localizedDescription)"
                    }
                }
            }
            run.cells.append(contentsOf: cells)
            done += cells.count
            current = run
            save(run)
        }
    }

    private func transcribe(_ rec: HistoryEntry, sttID: String, audio: [Float]) async -> Result<CachedSTT, Error> {
        let key = rec.id + "|" + sttID
        if let hit = sttCache[key] { return .success(hit) }
        guard let choice = Lab.STT(id: sttID) else { return .failure(CaptureError(message: "Unknown engine \(sttID)")) }
        let cfg = Lab.shared.pipelineConfig(for: choice, appName: rec.appName)
        let clock = ContinuousClock()
        let t0 = clock.now
        do {
            var apple = false
            if case .apple = choice { apple = true }
            let text = try await Lab.runSession(cfg.makeSession(), samples: audio, feedsBuffers: apple)
            let d = clock.now - t0
            let out = CachedSTT(text: text, seconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            sttCache[key] = out
            saveCache()
            return .success(out)
        } catch {
            return .failure(error)
        }
    }

    private func polishAll(_ jobs: [(Int, EvalPipeline, String)], appName: String?) async -> [(Int, Result<(String, Double, Double?), Error>)] {
        let c = AppSettings.shared.config
        func cfg(_ p: EvalPipeline) -> PipelineConfig? {
            guard let pol = p.polisher.flatMap(Lab.Polisher.init(id:)), let pr = p.prompt.flatMap(Lab.PromptChoice.init(rawValue:)) else { return nil }
            return Lab.shared.cleanupConfig(pol, pr, appName: c.cleanupUsesAppContext ? appName : nil)
        }
        let remote = jobs.filter { !($0.1.polisher ?? "").hasPrefix("apple") }
        let local = jobs.filter { ($0.1.polisher ?? "").hasPrefix("apple") }
        var out: [(Int, Result<(String, Double, Double?), Error>)] = []
        await withTaskGroup(of: (Int, Result<(String, Double, Double?), Error>).self) { group in
            for (i, p, input) in remote {
                guard let config = cfg(p) else { continue }
                group.addTask { (i, await Self.polishOne(input, config)) }
            }
            group.addTask { (-1, .success(("", 0, nil))) }
            for await r in group where r.0 >= 0 { out.append(r) }
        }
        for (i, p, input) in local {
            guard let config = cfg(p) else { continue }
            out.append((i, await Self.polishOne(input, config)))
        }
        return out
    }

    nonisolated private static func polishOne(_ input: String, _ cfg: PipelineConfig) async -> Result<(String, Double, Double?), Error> {
        let clock = ContinuousClock()
        let t0 = clock.now
        do {
            let (text, usage) = try await Lab.polishDetailed(input, cfg: cfg)
            let d = clock.now - t0
            return .success((RustCore.applyVocabulary(text, cfg.vocabulary),
                             Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18, usage?.cost))
        } catch {
            return .failure(error)
        }
    }

    private func judgeAll(_ cells: [EvalCell], model: String, listens: Bool, wav: URL) async -> [(Int, Result<(Double, String), Error>)] {
        let c = AppSettings.shared.config
        let provider = RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: model)
        let vocab = c.vocabulary
        // Reference transcript for the text judge: the reference engine's output for this recording.
        let reference = cells.first { $0.pipelineID.hasPrefix(c.labReferenceSTT + "|") && $0.sttText != nil }?.sttText
            ?? cells.first { $0.sttText != nil }?.sttText ?? ""
        struct A: Encodable, Sendable { let provider: RemoteProvider; let transcript: String; let candidate: String; let vocabulary: [VocabTerm]; let wavPath: String? }
        struct R: Decodable, Sendable { let score: Double; let notes: String }
        var out: [(Int, Result<(Double, String), Error>)] = []
        await withTaskGroup(of: (Int, Result<(Double, String), Error>).self) { group in
            for (i, cell) in cells.enumerated() {
                guard let text = cell.text, cell.error == nil else { continue }
                let args = A(provider: provider, transcript: reference, candidate: text, vocabulary: vocab, wavPath: listens ? wav.path : nil)
                group.addTask {
                    do {
                        let r = try await RustCore.callAsync("judge", args, as: R.self)
                        return (i, .success((r.score, r.notes)))
                    } catch { return (i, .failure(error)) }
                }
            }
            for await r in group { out.append(r) }
        }
        return out
    }

    // MARK: Persistence

    private func save(_ run: EvalRun) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(run).write(to: runsDir.appendingPathComponent(run.id + ".json"))
    }

    private func saveCache() {
        try? JSONEncoder().encode(sttCache).write(to: cacheURL)
    }

    // MARK: Aggregation

    func rows(_ run: EvalRun) -> [EvalRow] {
        run.pipelines.map { p in
            let cells = run.cells.filter { $0.pipelineID == p.id }
            let ok = cells.filter { $0.error == nil && $0.text != nil }
            func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
            let costs = ok.compactMap(\.cost)
            return EvalRow(pipeline: p, n: cells.count, failures: cells.count - ok.count,
                           score: mean(ok.compactMap(\.score)),
                           sttSeconds: mean(ok.compactMap(\.sttSeconds)),
                           cleanSeconds: p.polisher == nil ? nil : mean(ok.compactMap(\.cleanSeconds)),
                           costPer1k: costs.isEmpty ? nil : costs.reduce(0, +) / Double(costs.count) * 1000)
        }
    }

    /// Fastest end-to-end pipeline averaging 8+ (or fastest overall when unjudged).
    func best(_ run: EvalRun) -> EvalRow? {
        let rows = rows(run).filter { $0.failures == 0 && $0.totalSeconds != nil }
        let judged = rows.filter { $0.score != nil }
        let pool = judged.isEmpty ? rows : judged.filter { ($0.score ?? 0) >= 8 }
        return pool.min { ($0.totalSeconds ?? .infinity) < ($1.totalSeconds ?? .infinity) }
    }

    static func label(_ p: EvalPipeline) -> (stt: String, cleanup: String) {
        let stt = Lab.STT(id: p.stt)?.label ?? p.stt
        guard let pol = p.polisher.flatMap(Lab.Polisher.init(id:)) else { return (stt, "No cleanup") }
        let prompt = p.prompt.flatMap(Lab.PromptChoice.init(rawValue:))?.label ?? ""
        return (stt, "\(pol.label) · \(prompt)")
    }

    func recording(_ id: String) -> HistoryEntry? { HistoryStore.shared.entries.first { $0.id == id } }

    static func title(_ e: HistoryEntry) -> String {
        let words = (e.finalText.isEmpty ? e.rawText : e.finalText).split(separator: " ").prefix(8).joined(separator: " ")
        return words.isEmpty ? "Dictation" : words
    }

    /// CSV of every cell, for spreadsheets.
    func csv(_ run: EvalRun) -> String {
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func n(_ d: Double?) -> String { d.map { String(format: "%.4f", $0) } ?? "" }
        var lines = ["recording,stt,cleanup,stt_seconds,cleanup_seconds,total_seconds,cost_usd,score,text,notes,error"]
        let byID = Dictionary(uniqueKeysWithValues: run.pipelines.map { ($0.id, $0) })
        for c in run.cells {
            let l: (stt: String, cleanup: String) = byID[c.pipelineID].map(Self.label) ?? (stt: c.pipelineID, cleanup: "")
            lines.append([q(recording(c.recordingID).map(Self.title) ?? c.recordingID), q(l.stt), q(l.cleanup), n(c.sttSeconds), n(c.cleanSeconds),
                          n(c.totalSeconds), c.cost.map { String(format: "%.8f", $0) } ?? "", n(c.score), q(c.text), q(c.notes), q(c.error)]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
