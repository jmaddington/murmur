import Foundation
import Observation

/// Mirrors `history::Entry` in the Rust core.
struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var createdAt: Double
    var duration: Double = 0
    var rawText: String = ""
    var cleanedText: String?
    var finalText: String = ""
    var engine: String = ""
    var cleanupEngine: String?
    var appName: String?
    var microphone: String?
    var error: String?
    var audioPath: String?
    var textPurged: Bool = false
    /// Timings: key release → transcript, cleanup model time, key release → final text.
    var transcribeSeconds: Double?
    var polishSeconds: Double?
    var latencySeconds: Double?

    var date: Date { Date(timeIntervalSince1970: createdAt) }
    var wordCount: Int { finalText.split(whereSeparator: \.isWhitespace).count }
}

@MainActor @Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var entries: [HistoryEntry] = []
    let root: URL
    private var timer: Timer?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = E2E.isActive
            ? E2E.outDir.appendingPathComponent("history", isDirectory: true)
            : base.appendingPathComponent("Murmur/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func start() {
        purge()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { HistoryStore.shared.purge() }
        }
    }

    func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    /// Where the recorder should write audio for a new entry, or nil if audio isn't kept.
    func audioURL(for id: String) -> URL? {
        guard AppSettings.shared.config.audioRetentionDays != 0 else { return nil }
        let dir = folder(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audio.m4a")
    }

    func save(_ entry: HistoryEntry) {
        var e = entry
        if AppSettings.shared.config.transcriptRetentionDays == 0 {
            e.rawText = ""; e.cleanedText = nil; e.finalText = ""; e.textPurged = true
        }
        if e.textPurged && e.audioPath == nil {
            try? FileManager.default.removeItem(at: folder(for: e.id))
            return
        }
        struct A: Encodable { let root: String; let entry: HistoryEntry }
        do {
            let _: RustCore.Empty = try RustCore.call("history_save", A(root: root.path, entry: e))
        } catch {
            NSLog("Murmur: history save failed: \(error)")
        }
        reload()
    }

    func delete(_ entry: HistoryEntry) {
        struct A: Encodable { let root: String; let id: String }
        let _: RustCore.Empty? = try? RustCore.call("history_delete", A(root: root.path, id: entry.id))
        reload()
    }

    func deleteAll() {
        for e in entries { delete(e) }
    }

    func reload() {
        struct A: Encodable { let root: String }
        entries = (try? RustCore.call("history_list", A(root: root.path), as: [HistoryEntry].self)) ?? []
    }

    func purge() {
        struct A: Encodable { let root: String; let audioDays: Int; let transcriptDays: Int; let now: Double }
        struct R: Decodable { let audioRemoved: Int; let entriesRemoved: Int }
        let c = AppSettings.shared.config
        _ = try? RustCore.call("history_purge",
                               A(root: root.path, audioDays: c.audioRetentionDays, transcriptDays: c.transcriptRetentionDays,
                                 now: Date().timeIntervalSince1970),
                               as: R.self)
        reload()
    }

    // MARK: Stats for the home screen

    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }

    var wordsThisWeek: Int {
        let cutoff = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        return entries.filter { $0.createdAt >= cutoff }.reduce(0) { $0 + $1.wordCount }
    }

    var averageWPM: Int {
        let timed = entries.filter { $0.duration > 1 && $0.wordCount > 0 }
        let secs = timed.reduce(0) { $0 + $1.duration }
        guard secs > 0 else { return 0 }
        return Int(Double(timed.reduce(0) { $0 + $1.wordCount }) / (secs / 60))
    }

    /// Minutes saved versus typing at 45 WPM.
    var minutesSaved: Int {
        let typing = Double(totalWords) / 45
        let speaking = entries.reduce(0) { $0 + $1.duration } / 60
        return max(0, Int((typing - speaking).rounded()))
    }
}

// MARK: - Performance metrics

/// Latency statistics for one speech engine or cleanup model.
struct PerfRow: Identifiable {
    var label: String
    var count: Int
    var mean: Double
    var p50: Double
    var p90: Double
    /// Milliseconds per word / character of the text it produced.
    var msPerWord: Double?
    var msPerChar: Double?
    /// Seconds of audio per second of processing (speech engines only).
    var realtime: Double?
    var id: String { label }
}

extension HistoryStore {
    private static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    private static func row(_ label: String, _ items: [(secs: Double, text: String, audio: Double?)]) -> PerfRow {
        let secs = items.map(\.secs)
        let withText = items.filter { !$0.text.isEmpty }
        let words = withText.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let chars = withText.reduce(0) { $0 + $1.text.count }
        let textSecs = withText.reduce(0) { $0 + $1.secs }
        let audio = items.compactMap(\.audio).reduce(0, +)
        return PerfRow(label: label, count: items.count, mean: secs.reduce(0, +) / Double(max(secs.count, 1)),
                       p50: percentile(secs, 0.5), p90: percentile(secs, 0.9),
                       msPerWord: words > 0 ? textSecs / Double(words) * 1000 : nil,
                       msPerChar: chars > 0 ? textSecs / Double(chars) * 1000 : nil,
                       realtime: audio > 0 && secs.reduce(0, +) > 0 ? audio / secs.reduce(0, +) : nil)
    }

    /// Per speech engine: release → transcript.
    var speechPerformance: [PerfRow] {
        Dictionary(grouping: entries.filter { $0.transcribeSeconds != nil }, by: \.engine)
            .map { Self.row($0.key, $0.value.map { ($0.transcribeSeconds!, $0.rawText, $0.duration) }) }
            .sorted { $0.mean < $1.mean }
    }

    /// Per cleanup model: time inside the model.
    var polishPerformance: [PerfRow] {
        Dictionary(grouping: entries.filter { $0.polishSeconds != nil && $0.cleanupEngine != nil }, by: { $0.cleanupEngine! })
            .map { Self.row($0.key, $0.value.map { ($0.polishSeconds!, $0.cleanedText ?? "", nil) }) }
            .sorted { $0.mean < $1.mean }
    }

    /// Everything: release → text ready.
    var overallPerformance: PerfRow? {
        let xs = entries.filter { $0.latencySeconds != nil }
        guard !xs.isEmpty else { return nil }
        return Self.row("All dictations", xs.map { ($0.latencySeconds!, $0.finalText, $0.duration) })
    }
}
