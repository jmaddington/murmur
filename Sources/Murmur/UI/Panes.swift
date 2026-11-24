import AVFoundation
import AppKit
import SwiftUI

// MARK: - Microphones

@MainActor @Observable
final class MicTester {
    var level: Float = 0
    var running = false
    var deviceName = ""
    private var source: MicrophoneSource?

    func toggle() { running ? stop() : start() }

    func start() {
        guard let device = MicrophoneManager.shared.candidates().first else { return }
        let src = MicrophoneSource(device: device)
        src.onLevel = { [weak self] l in Task { @MainActor in self?.level = l } }
        do {
            try src.start(recordingTo: nil)
            source = src
            deviceName = device.name
            running = true
        } catch {
            deviceName = error.localizedDescription
        }
    }

    func stop() {
        _ = source?.stop()
        source = nil
        running = false
        level = 0
    }
}

struct MicrophonesPane: View {
    @Bindable var settings = AppSettings.shared
    var mics = MicrophoneManager.shared
    @ViewState private var tester = MicTester()

    private var activeUID: String? { mics.candidates().first?.uid }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: Pane.microphones.symbol, color: Pane.microphones.color, title: "Microphones",
                       subtitle: "Drag to set priority. Murmur uses the first one that's connected.")
            Form {
                Section {
                    List {
                        // Rows get plain values plus an id-keyed binding: an index-based
                        // projection of `$settings.config.microphones` goes stale (and traps
                        // out of range) once a row is forgotten, and reading one inside a
                        // mutation of `config` is an exclusivity violation.
                        ForEach(Array(settings.config.microphones.enumerated()), id: \.element.id) { idx, mic in
                            let uid = mic.uid
                            MicRow(mic: micBinding(mic), rank: idx + 1, connected: mics.isConnected(uid),
                                   active: uid == activeUID, onForget: { forget(uid) })
                        }
                        .onMove { from, to in settings.moveMicrophones(fromOffsets: from, toOffset: to) }
                    }
                    .frame(minHeight: CGFloat(max(settings.config.microphones.count, 1)) * 46)
                    .scrollDisabled(true)
                } header: {
                    Text("Priority")
                } footer: {
                    Text("If none of these are available, Murmur falls back to the system default input.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Section("Test") {
                    HStack(spacing: 12) {
                        Button(tester.running ? "Stop" : "Test microphone") { tester.toggle() }
                        if tester.running {
                            LevelMeter(level: tester.level).frame(maxWidth: 260)
                            Text(tester.deviceName).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { mics.refresh() }
        .onDisappear { tester.stop() }
    }

    private func forget(_ uid: String) {
        settings.removeMicrophones { $0.uid == uid }
    }

    private func micBinding(_ snapshot: MicRecord) -> Binding<MicRecord> {
        let settings = settings
        let uid = snapshot.uid
        return Binding(
            get: { settings.config.microphones.first { $0.uid == uid } ?? snapshot },
            set: { new in
                var list = settings.config.microphones
                guard let i = list.firstIndex(where: { $0.uid == uid }) else { return }
                list[i] = new
                settings.config.microphones = list
            })
    }
}

private struct MicRow: View {
    @Binding var mic: MicRecord
    var rank: Int
    var connected: Bool
    var active: Bool
    var onForget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary)))
            Image(systemName: icon).frame(width: 18).foregroundStyle(connected ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(mic.name).font(.system(size: 13, weight: .medium)).foregroundStyle(connected ? .primary : .secondary)
                if active { Text("In use").font(.system(size: 11)).foregroundStyle(Theme.accent) }
                else if !connected { Text("Not connected").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            if !connected {
                Button("Forget", action: onForget).buttonStyle(.borderless).font(.system(size: 12))
            }
            Toggle("", isOn: $mic.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 4)
        .opacity(mic.enabled ? 1 : 0.55)
    }

    private var icon: String {
        let n = mic.name.lowercased()
        if n.contains("airpods") { return "airpods" }
        if n.contains("macbook") || n.contains("built-in") { return "laptopcomputer" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("display") || n.contains("studio") { return "display" }
        if n.contains("headset") || n.contains("headphone") { return "headphones" }
        return "mic"
    }
}

// MARK: - Model picker (OpenRouter / OpenAI-compatible)

struct ModelField: View {
    @Binding var model: String
    var provider: () -> RemoteProvider
    var audioOnly: Bool
    @ViewState private var models: [RemoteModel] = []
    @ViewState private var loading = false
    @ViewState private var error: String?

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $model, prompt: Text("provider/model"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Menu {
                if let error { Text(error) }
                ForEach(filtered.prefix(200)) { m in
                    Button(m.id) { model = m.id }
                }
            } label: {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "list.bullet") }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Browse models")
            .onTapGesture {}
            .task(id: "load") { await load() }
        }
    }

    private var filtered: [RemoteModel] { audioOnly ? models.filter(\.audioInput) : models }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            models = try await RustCore.listModels(provider())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Transcription

struct TranscriptionPane: View {
    @Bindable var settings = AppSettings.shared
    @ViewState private var locales: [Locale] = []
    @ViewState private var status: AppleSpeech.State = .checking
    @ViewState private var progress: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: Pane.transcription.symbol, color: Pane.transcription.color, title: "Transcription",
                       subtitle: "Choose the model that turns your voice into text.")
            Form {
                Section {
                    HStack(spacing: 12) {
                        ForEach(TranscriptionEngine.allCases) { e in
                            ChoiceCard(symbol: e.symbol, title: e.label, detail: e.detail,
                                       selected: settings.config.engine == e) { settings.config.engine = e }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                switch settings.config.engine {
                case .apple: appleSection
                case .local: LocalModelsSection(selection: $settings.config.localModel)
                case .openrouter: openRouterSection
                case .openaiCompatible: customSection
                }
            }
            .formStyle(.grouped)
        }
        .task { locales = await AppleSpeech.supportedLocales() }
        .task(id: "\(settings.config.localeIdentifier)|\(settings.config.appleModel.rawValue)") { await refreshStatus() }
    }

    @ViewBuilder private var appleSection: some View {
        Section("On-device") {
            Picker("Language", selection: $settings.config.localeIdentifier) {
                if !locales.contains(where: { $0.identifier(.bcp47) == settings.config.localeIdentifier }) {
                    Text(settings.config.localeIdentifier).tag(settings.config.localeIdentifier)
                }
                ForEach(locales, id: \.self) { l in
                    Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier(.bcp47))
                }
            }
            Picker("Model", selection: $settings.config.appleModel) {
                ForEach(AppleSpeechModel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(settings.config.appleModel.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            LabeledContent("Status") {
                HStack(spacing: 10) {
                    switch status {
                    case .checking: ProgressView().controlSize(.small)
                    case .ready: StatusPill(text: "Ready", tone: .good)
                    case .needsDownload:
                        StatusPill(text: "Not downloaded", tone: .warn)
                        Button("Download") { Task { await download() } }
                    case .downloading:
                        ProgressView(value: progress).frame(width: 120)
                        Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    case .unsupported: StatusPill(text: "Language not supported", tone: .bad)
                    case .failed(let m): StatusPill(text: m, tone: .bad)
                    }
                }
            }
        }
    }

    @ViewBuilder private var openRouterSection: some View {
        Section {
            LabeledContent("API key") { KeychainField(account: .openrouter, prompt: "sk-or-…") }
            LabeledContent("Model") {
                ModelField(model: $settings.config.openrouterTranscribeModel, provider: {
                    RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: "")
                }, audioOnly: true)
            }
        } header: {
            Text("OpenRouter")
        } footer: {
            Text("Audio is sent as WAV to an audio-capable chat model. Your vocabulary is included in the prompt.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var customSection: some View {
        Section {
            LabeledContent("Base URL") {
                TextField("", text: $settings.config.customTranscribeURL, prompt: Text("http://localhost:8080/v1"))
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Model") {
                TextField("", text: $settings.config.customTranscribeModel, prompt: Text("whisper-1")).textFieldStyle(.roundedBorder)
            }
            LabeledContent("API key") { KeychainField(account: .customTranscribe, prompt: "Optional") }
        } header: {
            Text("OpenAI-compatible server")
        } footer: {
            Text("Calls POST {base}/audio/transcriptions. Works with whisper.cpp's server, faster-whisper servers, Groq and OpenAI.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func refreshStatus() async {
        status = .checking
        status = await AppleSpeech.status(locale: Locale(identifier: settings.config.localeIdentifier), model: settings.config.appleModel)
    }

    private func download() async {
        status = .downloading(0)
        progress = 0
        do {
            try await AppleSpeech.ensureInstalled(locale: Locale(identifier: settings.config.localeIdentifier),
                                                  model: settings.config.appleModel) { p in
                Task { @MainActor in progress = p }
            }
            await refreshStatus()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Cleanup

struct CleanupPane: View {
    @Bindable var settings = AppSettings.shared
    @ViewState private var sample = "um so i think we should uh move the meeting to tuesday no wait wednesday and invite jay queue reyes"
    @ViewState private var output = ""
    @ViewState private var running = false
    @ViewState private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: Pane.cleanup.symbol, color: Pane.cleanup.color, title: "Cleanup",
                       subtitle: "An LLM polishes each dictation: fixes mishearings, fillers and self-corrections.")
            Form {
                Section {
                    Toggle(isOn: $settings.config.cleanupEnabled.animation()) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Polish transcripts").font(.system(size: 13, weight: .semibold))
                            Text("Adds a moment of latency. If cleanup fails, the raw transcript is used.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                if settings.config.cleanupEnabled {
                    Section {
                        HStack(spacing: 12) {
                            ForEach(CleanupEngine.allCases) { e in
                                ChoiceCard(symbol: e.symbol, title: e.label, detail: e.detail,
                                           selected: settings.config.cleanupEngine == e) { settings.config.cleanupEngine = e }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    engineSection
                    Section("Style") {
                        Toggle("Adapt to the app you're typing in", isOn: $settings.config.cleanupUsesAppContext)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("House style").font(.system(size: 12, weight: .medium))
                            TextEditor(text: $settings.config.cleanupStyle)
                                .font(.system(size: 12.5))
                                .frame(height: 64)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                                .overlay(alignment: .topLeading) {
                                    if settings.config.cleanupStyle.isEmpty {
                                        Text("e.g. British spelling. Never use em dashes. Keep it concise.")
                                            .font(.system(size: 12.5)).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                                    }
                                }
                        }
                    }
                    promptSection
                    playground
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private var engineSection: some View {
        switch settings.config.cleanupEngine {
        case .apple:
            Section("Apple Intelligence") {
                LabeledContent("Status") {
                    if let why = Cleanup.appleAvailability { StatusPill(text: why, tone: .warn) }
                    else { StatusPill(text: "Ready · on-device", tone: .good) }
                }
            }
        case .openrouter:
            Section("OpenRouter") {
                LabeledContent("API key") { KeychainField(account: .openrouter, prompt: "sk-or-…") }
                LabeledContent("Model") {
                    ModelField(model: $settings.config.openrouterCleanupModel, provider: {
                        RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: "")
                    }, audioOnly: settings.config.cleanupSendsAudio)
                }
                Toggle(isOn: $settings.config.cleanupSendsAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send audio with the transcript")
                        Text("Lets the model listen to what you actually said. Requires an audio-capable model.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
        case .openaiCompatible:
            Section("Local / custom") {
                LabeledContent("Base URL") {
                    TextField("", text: $settings.config.customCleanupURL, prompt: Text("http://localhost:11434/v1")).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Model") {
                    ModelField(model: $settings.config.customCleanupModel, provider: {
                        RemoteProvider(kind: .openaiCompatible, baseUrl: settings.config.customCleanupURL,
                                       apiKey: Keychain.get(.customCleanup), model: "")
                    }, audioOnly: false)
                }
                LabeledContent("API key") { KeychainField(account: .customCleanup, prompt: "Optional") }
            }
        }
    }

    @ViewBuilder private var promptSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.config.cleanupUseCustomPrompt },
                set: { on in
                    if on && settings.config.cleanupCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        settings.config.cleanupCustomPrompt = RustCore.promptInfo.defaultTemplate
                    }
                    withAnimation { settings.config.cleanupUseCustomPrompt = on }
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Write my own prompt").font(.system(size: 13, weight: .semibold))
                    Text("Replaces the built-in instructions. Your transcript is always sent separately as the message to clean.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if settings.config.cleanupUseCustomPrompt {
                PromptEditor(prompt: $settings.config.cleanupCustomPrompt,
                             hasVocabulary: !settings.config.vocabulary.isEmpty,
                             preview: { renderedPreview })
            }
        } header: {
            Text("Prompt")
        }
    }

    /// The prompt exactly as the model would get it right now (app shown as an example).
    private var renderedPreview: String {
        var cfg = PipelineConfig.current(appName: settings.config.cleanupUsesAppContext ? "Slack" : nil)
        cfg.cleanupCustomPrompt = settings.config.cleanupCustomPrompt
        let audio = settings.config.cleanupSendsAudio && settings.config.cleanupEngine == .openrouter
        return RustCore.cleanupSystemPrompt(cfg.promptContext(withAudio: audio))
    }

    private var playground: some View {
        Section("Try it") {
            TextField("Raw transcript", text: $sample, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button {
                    Task { await run() }
                } label: {
                    Label("Polish", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || sample.isEmpty)
                if running { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !output.isEmpty || error != nil {
                Text(error ?? output)
                    .font(.system(size: 13))
                    .foregroundStyle(error == nil ? .primary : Color.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.07)))
            }
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        var cfg = PipelineConfig.current(appName: nil)
        cfg.cleanupEnabled = true
        cfg.cleanupSendsAudio = false
        do {
            let pre = RustCore.applyVocabulary(sample, cfg.vocabulary)
            output = RustCore.applyVocabulary(try await Cleanup.run(pre, config: cfg, samples: []), cfg.vocabulary)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Vocabulary

struct VocabularyPane: View {
    @Bindable var settings = AppSettings.shared
    @ViewState private var newTerm = ""
    @ViewState private var newSounds = ""
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: Pane.vocabulary.symbol, color: Pane.vocabulary.color, title: "Vocabulary",
                       subtitle: "Names, jargon and acronyms Murmur should always get right.")
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("", text: $newTerm, prompt: Text("Word or phrase — e.g. Kubernetes"))
                            .focused($focus)
                        TextField("", text: $newSounds, prompt: Text("Often heard as (optional, comma-separated)"))
                        Button { add() } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderedProminent)
                            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .onSubmit(add)
                } footer: {
                    Text("Terms bias the on-device recognizer, are included in model prompts, and misheard variants are corrected automatically.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Section("\(settings.config.vocabulary.count) terms") {
                    if settings.config.vocabulary.isEmpty {
                        Text("No terms yet.").foregroundStyle(.secondary)
                    }
                    // Plain values, not `$settings.config.vocabulary` bindings: the delete
                    // closure used to read the row's Binding (→ `settings.config`) from
                    // inside `settings.config.vocabulary.removeAll`, which aborted the app
                    // with a "simultaneous accesses" exclusivity violation.
                    ForEach(settings.config.vocabulary) { t in
                        let id = t.id
                        VocabRow(term: t) { settings.removeVocabulary { $0.id == id } }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let sounds = newSounds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        withAnimation { settings.config.vocabulary.insert(VocabTerm(term: term, soundsLike: sounds), at: 0) }
        newTerm = ""
        newSounds = ""
        focus = true
    }
}

private struct VocabRow: View {
    var term: VocabTerm
    var onDelete: () -> Void
    @ViewState private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(term.term).font(.system(size: 13, weight: .semibold))
            if !term.soundsLike.isEmpty {
                Image(systemName: "arrow.left").font(.system(size: 10)).foregroundStyle(.tertiary)
                FlowChips(items: term.soundsLike)
            }
            Spacer()
            Button(action: onDelete) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hover ? 1 : 0.35)
        }
        .onHover { hover = $0 }
    }
}

private struct FlowChips: View {
    var items: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { s in
                Text(s)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
    }
}

// MARK: - History

@MainActor @Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    var playingID: String?
    private var player: AVAudioPlayer?

    func toggle(_ e: HistoryEntry) {
        if playingID == e.id { stop(); return }
        guard let p = e.audioPath, let pl = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: p)) else { return }
        player = pl
        pl.delegate = self
        pl.play()
        playingID = e.id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingID = nil }
    }
}

struct HistoryPane: View {
    @Bindable var settings = AppSettings.shared
    var history = HistoryStore.shared
    @ViewState private var query = ""
    @ViewState private var player = ClipPlayer()
    @ViewState private var retrying: String?
    @ViewState private var confirmDeleteAll = false

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.finalText.localizedCaseInsensitiveContains(query) || $0.rawText.localizedCaseInsensitiveContains(query)
                || ($0.appName ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: Pane.history.symbol, color: Pane.history.color, title: "History",
                       subtitle: "Recordings and transcripts stay on this Mac, for as long as you choose.")
            HStack(spacing: 18) {
                retentionPicker("Keep audio", $settings.config.audioRetentionDays)
                retentionPicker("Keep transcripts", $settings.config.transcriptRetentionDays)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(history.root) }
                Button("Delete All…", role: .destructive) { confirmDeleteAll = true }
                    .disabled(history.entries.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            if history.entries.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "waveform",
                                       description: Text("Hold your shortcut and start talking."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { e in
                            HistoryCard(entry: e, playing: player.playingID == e.id, retrying: retrying == e.id,
                                        onPlay: { player.toggle(e) },
                                        onRetry: { retry(e) },
                                        onDelete: { withAnimation { history.delete(e) } })
                        }
                    }
                    .padding(20)
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Search dictations")
            }
        }
        .onChange(of: settings.config.audioRetentionDays) { history.purge() }
        .onChange(of: settings.config.transcriptRetentionDays) { history.purge() }
        .onAppear { history.reload() }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete all recordings and transcripts?", isPresented: $confirmDeleteAll) {
            Button("Delete All", role: .destructive) { history.deleteAll() }
        }
    }

    private func retentionPicker(_ title: String, _ value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            ForEach(Retention.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .fixedSize()
    }

    private func retry(_ e: HistoryEntry) {
        retrying = e.id
        Task {
            if let text = await DictationController.shared.retranscribe(e) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            retrying = nil
        }
    }
}

private struct HistoryCard: View {
    var entry: HistoryEntry
    var playing: Bool
    var retrying: Bool
    var onPlay: () -> Void
    var onRetry: () -> Void
    var onDelete: () -> Void
    @ViewState private var hover = false
    @ViewState private var copied = false
    @ViewState private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                if let app = entry.appName { meta(app, "app.badge") }
                meta(HUDView.clock(entry.duration), "timer")
                if entry.cleanedText != nil { meta("Polished", "sparkles") }
                Spacer()
                actions.opacity(hover ? 1 : 0)
            }
            Group {
                if entry.textPurged {
                    Text("Transcript expired — audio retained").italic().foregroundStyle(.secondary)
                } else if entry.finalText.isEmpty {
                    Text(entry.error ?? "No speech detected").foregroundStyle(.secondary)
                } else {
                    Text(showRaw ? entry.rawText : entry.finalText).textSelection(.enabled)
                }
            }
            .font(.system(size: 13.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            if let err = entry.error, !entry.finalText.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(hover ? 0.10 : 0.04)))
        .onHover { hover = $0 }
    }

    private func meta(_ s: String, _ symbol: String) -> some View {
        Label(s, systemImage: symbol)
            .font(.system(size: 11)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if entry.cleanedText != nil {
                iconButton(showRaw ? "text.badge.checkmark" : "text.badge.xmark", showRaw ? "Show polished" : "Show raw") { showRaw.toggle() }
            }
            if entry.audioPath != nil {
                iconButton(playing ? "stop.fill" : "play.fill", playing ? "Stop" : "Play recording", action: onPlay)
                if retrying { ProgressView().controlSize(.mini).frame(width: 26) }
                else { iconButton("arrow.clockwise", "Transcribe again (copies result)", action: onRetry) }
            }
            if !entry.finalText.isEmpty {
                iconButton(copied ? "checkmark" : "doc.on.doc", "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.finalText, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                }
            }
            iconButton("trash", "Delete", action: onDelete)
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 22).contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Prompt editor

struct PromptEditor: View {
    @Binding var prompt: String
    var hasVocabulary: Bool
    var preview: () -> String
    @ViewState private var selection: TextSelection?
    @ViewState private var showPreview = false

    private var mentionsVocabulary: Bool {
        let p = prompt.lowercased().replacingOccurrences(of: " ", with: "")
        return ["{{vocabulary}}", "{{vocabulary_section}}", "{{terms}}"].contains { p.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $prompt, selection: $selection)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            Text("Placeholders — click to insert at the cursor")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(RustCore.promptInfo.placeholders, id: \.self) { p in
                    Button { insert("{{\(p.name)}}") } label: {
                        Text("{{\(p.name)}}")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.accent.opacity(0.1)))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help(p.description)
                }
            }

            if hasVocabulary && !mentionsVocabulary {
                Label("This prompt doesn't use your vocabulary. Add {{vocabulary_section}} so the model spells your terms right. (Murmur still corrects them after cleanup.)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            }

            HStack {
                Button("Reset to built-in") { prompt = RustCore.promptInfo.defaultTemplate }
                    .disabled(prompt == RustCore.promptInfo.defaultTemplate)
                Spacer()
                Toggle("Preview", isOn: $showPreview.animation()).toggleStyle(.button)
            }
            .controlSize(.small)

            if showPreview {
                ScrollView {
                    Text(preview())
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.06)))
            }
        }
        .padding(.vertical, 4)
    }

    private func insert(_ token: String) {
        if case .selection(let range)? = selection?.indices,
           range.lowerBound >= prompt.startIndex, range.upperBound <= prompt.endIndex {
            let offset = prompt.distance(from: prompt.startIndex, to: range.lowerBound) + token.count
            prompt.replaceSubrange(range, with: token)
            let caret = prompt.index(prompt.startIndex, offsetBy: offset)
            selection = TextSelection(insertionPoint: caret)
        } else {
            prompt += (prompt.hasSuffix("\n") || prompt.isEmpty ? "" : " ") + token
        }
    }
}

// MARK: - Open models

struct LocalModelsSection: View {
    @Binding var selection: LocalModel
    var store = LocalModelStore.shared

    var body: some View {
        Section {
            ForEach(LocalModel.allCases) { m in row(m) }
        } header: {
            Text("Open models")
        } footer: {
            Text("Models are stored in ~/Library/Application Support/Murmur/Models. Voxtral runs in a private Python environment Murmur sets up with uv — nothing is installed system-wide.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { store.refresh() }
    }

    @ViewBuilder private func row(_ m: LocalModel) -> some View {
        let state = store.state(m)
        let selected = selection == m
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(selected ? Theme.accent : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.label).font(.system(size: 13, weight: .semibold))
                    Text(m.vendor).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(m.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if m.comfortableRAM > 0 && store.physicalMemory < m.comfortableRAM {
                    Label("This Mac has \(store.physicalMemory >> 30) GB of memory; expect a few seconds per dictation.",
                          systemImage: "tortoise").font(.system(size: 11)).foregroundStyle(.orange)
                }
                if case .installing(let p, let step) = state {
                    HStack(spacing: 8) {
                        ProgressView(value: p).frame(maxWidth: 220)
                        Text(step).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.top, 2)
                }
                if case .failed(let why) = state {
                    Text(why).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                switch state {
                case .ready:
                    StatusPill(text: "Ready", tone: .good)
                    Button("Remove", role: .destructive) { store.remove(m) }
                        .buttonStyle(.link).font(.system(size: 11))
                case .installing:
                    Button("Cancel") { store.cancelInstall(m) }.controlSize(.small)
                case .notInstalled, .failed:
                    Button { store.install(m); selection = m } label: {
                        Label("Download · \(m.downloadSize)", systemImage: "arrow.down.circle")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { selection = m }
    }
}
