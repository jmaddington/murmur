import AppKit
import Foundation
import Observation
import Security
import ServiceManagement

// MARK: - Model

struct VocabTerm: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var term: String
    var soundsLike: [String] = []

    init(term: String, soundsLike: [String] = []) {
        self.term = term
        self.soundsLike = soundsLike
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        term = try c.decode(String.self, forKey: .term)
        soundsLike = (try? c.decode([String].self, forKey: .soundsLike)) ?? []
    }
}

enum TriggerModifier: String, Codable, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fn: "fn  🌐"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        }
    }
    var keyCode: UInt16 {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: .function
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        }
    }
}

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value (device-independent bits only).
    var modifiers: UInt
    static let `default` = KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue) // ⌥Space
}

enum TriggerKind: String, Codable, CaseIterable, Identifiable {
    case modifier, shortcut
    var id: String { rawValue }
}

enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case apple, local, openrouter, openaiCompatible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: "On-device"
        case .local: "Open models"
        case .openrouter: "OpenRouter"
        case .openaiCompatible: "Custom server"
        }
    }
    var detail: String {
        switch self {
        case .apple: "Apple's speech model. Private, instant, works offline."
        case .local: "Parakeet or Voxtral, downloaded once and run on this Mac. Private and offline."
        case .openrouter: "Audio-capable models such as Gemini or GPT-4o via OpenRouter."
        case .openaiCompatible: "Any OpenAI-compatible /audio/transcriptions endpoint — a local whisper.cpp server, Groq, OpenAI."
        }
    }
    var symbol: String {
        switch self {
        case .apple: "lock.shield"
        case .local: "cpu"
        case .openrouter: "globe"
        case .openaiCompatible: "server.rack"
        }
    }
}

enum CleanupEngine: String, Codable, CaseIterable, Identifiable {
    case apple, openrouter, openaiCompatible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .openrouter: "OpenRouter"
        case .openaiCompatible: "Local / custom"
        }
    }
    var detail: String {
        switch self {
        case .apple: "On-device foundation model. Nothing leaves your Mac."
        case .openrouter: "Claude, GPT, Gemini and hundreds more. Can listen to the audio too."
        case .openaiCompatible: "Ollama, LM Studio or any OpenAI-compatible chat endpoint."
        }
    }
    var symbol: String {
        switch self {
        case .apple: "apple.intelligence"
        case .openrouter: "globe"
        case .openaiCompatible: "desktopcomputer"
        }
    }
}

struct MicRecord: Codable, Hashable, Identifiable {
    var uid: String
    var name: String
    var enabled = true
    var id: String { uid }
}

/// Retention in days; -1 keeps forever, 0 never stores.
enum Retention: Int, CaseIterable, Identifiable {
    case never = 0, day = 1, week = 7, month = 30, quarter = 90, year = 365, forever = -1
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .never: "Don't keep"
        case .day: "1 day"
        case .week: "1 week"
        case .month: "30 days"
        case .quarter: "90 days"
        case .year: "1 year"
        case .forever: "Forever"
        }
    }
}

struct Config: Codable {
    // Trigger
    var triggerKind: TriggerKind = .modifier
    var triggerModifier: TriggerModifier = .fn
    var shortcut: KeyCombo = .default

    // Microphones (ordered by priority)
    var microphones: [MicRecord] = []

    // Transcription
    var engine: TranscriptionEngine = .apple
    var appleModel: AppleSpeechModel = .speech
    var localModel: LocalModel = .parakeetV3
    var localeIdentifier: String = Locale.current.identifier(.bcp47)
    var openrouterTranscribeModel = "google/gemini-2.5-flash"
    var customTranscribeURL = "http://localhost:8080/v1"
    var customTranscribeModel = "whisper-1"

    // Cleanup
    var cleanupEnabled = false
    var cleanupEngine: CleanupEngine = .apple
    var openrouterCleanupModel = "anthropic/claude-haiku-4.5"
    var cleanupSendsAudio = false
    var customCleanupURL = "http://localhost:11434/v1"
    var customCleanupModel = "llama3.2"
    var cleanupStyle = ""
    var cleanupUsesAppContext = true
    /// When on, `cleanupCustomPrompt` replaces the built-in cleanup prompt.
    var cleanupUseCustomPrompt = false
    var cleanupCustomPrompt = ""

    // Vocabulary
    var vocabulary: [VocabTerm] = []

    // History
    var audioRetentionDays: Int = Retention.week.rawValue
    var transcriptRetentionDays: Int = Retention.month.rawValue

    // Behaviour
    var playSounds = true
    var soundStyle: SoundStyle = .murmur
    var soundVolume: Double = 0.6
    var restoreClipboard = true
    var hasOnboarded = false

    init() {}

    // Tolerant decoding so adding fields never wipes a user's settings.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decode(T.self, forKey: k) { v = x } }
        d(.triggerKind, &triggerKind); d(.triggerModifier, &triggerModifier); d(.shortcut, &shortcut)
        d(.microphones, &microphones); d(.engine, &engine); d(.appleModel, &appleModel); d(.localModel, &localModel); d(.localeIdentifier, &localeIdentifier)
        d(.openrouterTranscribeModel, &openrouterTranscribeModel); d(.customTranscribeURL, &customTranscribeURL)
        d(.customTranscribeModel, &customTranscribeModel); d(.cleanupEnabled, &cleanupEnabled)
        d(.cleanupEngine, &cleanupEngine); d(.openrouterCleanupModel, &openrouterCleanupModel)
        d(.cleanupSendsAudio, &cleanupSendsAudio); d(.customCleanupURL, &customCleanupURL)
        d(.customCleanupModel, &customCleanupModel); d(.cleanupStyle, &cleanupStyle)
        d(.cleanupUsesAppContext, &cleanupUsesAppContext); d(.vocabulary, &vocabulary)
        d(.cleanupUseCustomPrompt, &cleanupUseCustomPrompt); d(.cleanupCustomPrompt, &cleanupCustomPrompt)
        d(.audioRetentionDays, &audioRetentionDays); d(.transcriptRetentionDays, &transcriptRetentionDays)
        d(.playSounds, &playSounds); d(.soundStyle, &soundStyle); d(.soundVolume, &soundVolume); d(.restoreClipboard, &restoreClipboard); d(.hasOnboarded, &hasOnboarded)
    }
}

// MARK: - Store

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private static let key = "config.v1"

    var config: Config {
        didSet { save() }
    }

    private let defaults: UserDefaults = E2E.isActive ? UserDefaults(suiteName: "com.internal.murmur.e2e")! : .standard

    private init() {
        if let data = defaults.data(forKey: Self.key),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
        } else {
            config = Config()
        }
    }

    // Collection edits driven by the UI go through these helpers. They edit a
    // copy and assign it back in one step, so a predicate (or anything it
    // captures, e.g. a SwiftUI row Binding that reads `config`) can never read
    // `config` while it is being modified — `config.vocabulary.removeAll { … }`
    // with such a predicate is an exclusivity violation that aborts the app.

    func removeVocabulary(where shouldRemove: (VocabTerm) -> Bool) {
        var list = config.vocabulary
        list.removeAll(where: shouldRemove)
        config.vocabulary = list
    }

    func removeMicrophones(where shouldRemove: (MicRecord) -> Bool) {
        var list = config.microphones
        list.removeAll(where: shouldRemove)
        config.microphones = list
    }

    func moveMicrophones(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = config.microphones
        // Hand-rolled (no SwiftUI import here); same semantics as Array.move(fromOffsets:toOffset:).
        let valid = source.filter { list.indices.contains($0) }
        guard !valid.isEmpty, (0...list.count).contains(destination) else { return }
        let moving = valid.map { list[$0] }
        let insertAt = destination - valid.filter { $0 < destination }.count
        for i in valid.reversed() { list.remove(at: i) }
        list.insert(contentsOf: moving, at: insertAt)
        config.microphones = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: .murmurSettingsChanged, object: nil)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Murmur: launch-at-login change failed: \(error)")
            }
        }
    }
}

extension Notification.Name {
    static let murmurSettingsChanged = Notification.Name("murmurSettingsChanged")
}

// MARK: - Keychain

enum Keychain {
    enum Account: String { case openrouter, customTranscribe, customCleanup }
    private static var service: String { E2E.isActive ? "com.internal.murmur.e2e" : "com.internal.murmur" }

    static func get(_ account: Account) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static func set(_ value: String, for account: Account) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
