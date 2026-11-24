import AVFAudio
import SwiftUI

struct LabPane: View {
    @Bindable var lab = Lab.shared
    @Bindable var settings = AppSettings.shared
    var history = HistoryStore.shared
    var store = LocalModelStore.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: Pane.lab.symbol, color: Pane.lab.color, title: "Lab",
                       subtitle: "Replay real recordings through other models and prompts. Find the fastest setup that still nails it.")
            Form {
                if lab.entries.isEmpty {
                    Section {
                        Text("No recordings with saved audio yet. Dictate something (and keep audio in History → Retention), then come back.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabRecordingSection(lab: lab)
                    LabTranscribeSection(lab: lab, settings: settings, store: store)
                    LabPolishSection(lab: lab, settings: settings)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { store.refresh() }
    }
}

// MARK: - Recording

private struct LabRecordingSection: View {
    @Bindable var lab: Lab
    @ViewState private var player: AVAudioPlayer?
    @ViewState private var playing = false

    var body: some View {
        Section("Recording") {
            Picker("Recording", selection: Binding(get: { lab.entry?.id ?? "" }, set: { lab.select($0) })) {
                ForEach(lab.entries) { e in
                    Text(title(e)).tag(e.id)
                }
            }
            if let e = lab.entry {
                HStack(alignment: .top, spacing: 10) {
                    Button { toggle(e) } label: {
                        Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(e.engine)\(e.cleanupEngine.map { " → \($0)" } ?? "") · \(HUDView.clock(e.duration))\(e.appName.map { " · \($0)" } ?? "")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        LabeledText(label: "Transcript", text: e.rawText)
                        if let c = e.cleanedText { LabeledText(label: "Polished", text: c) }
                    }
                }
            }
        }
        .onChange(of: lab.entryID) { stop() }
        .onDisappear { stop() }
    }

    private func title(_ e: HistoryEntry) -> String {
        let when = e.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let words = e.rawText.split(separator: " ").prefix(8).joined(separator: " ")
        return "\(when) · \(HUDView.clock(e.duration)) · \(words.isEmpty ? "(no text)" : words + "…")"
    }

    private func toggle(_ e: HistoryEntry) {
        if playing { stop(); return }
        guard let path = e.audioPath, let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        player = p
        p.play()
        playing = true
        let d = p.duration
        Task { try? await Task.sleep(for: .seconds(d + 0.1)); if player === p { stop() } }
    }

    private func stop() {
        player?.stop()
        player = nil
        playing = false
    }
}

private struct LabeledText: View {
    var label: String
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            Text(text.isEmpty ? "—" : text).font(.system(size: 12.5)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Transcribe

private struct LabTranscribeSection: View {
    @Bindable var lab: Lab
    @Bindable var settings: AppSettings
    var store: LocalModelStore

    var body: some View {
        Section {
            ChipGrid {
                ForEach(AppleSpeechModel.allCases) { m in chip(.apple(m)) }
                ForEach(LocalModel.allCases.filter { store.state($0) == .ready }) { m in chip(.local(m)) }
                ForEach(settings.config.labTranscribeModels, id: \.self) { m in chip(.openrouter(m)) }
                chip(.custom)
            }
            ModelListEditor(models: $settings.config.labTranscribeModels, audioOnly: true,
                            placeholder: "Add an OpenRouter audio model")
            HStack {
                RunButton(title: "Transcribe", running: lab.transcribing,
                          disabled: lab.sttChoices.isEmpty) { Task { await lab.transcribe() } }
                Text("Runs one model at a time so timings are fair. Vocabulary corrections are applied, as in real dictation.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(lab.sttResults) { r in
                ResultCard(result: r, pickable: r.status == .done, picked: lab.inputID == r.id) { lab.inputID = r.id }
            }
        } header: {
            Text("1 · Transcribe")
        }
    }

    private func chip(_ s: Lab.STT) -> some View {
        Chip(label: s.label, on: lab.sttChoices.contains(s)) {
            if lab.sttChoices.contains(s) { lab.sttChoices.remove(s) } else { lab.sttChoices.insert(s) }
        }
    }
}

// MARK: - Polish

private struct LabPolishSection: View {
    @Bindable var lab: Lab
    @Bindable var settings: AppSettings
    @ViewState private var editingPrompt = false

    var body: some View {
        Section {
            Picker("Input", selection: $lab.inputID) {
                Text("Original transcript").tag("original")
                ForEach(lab.sttResults.filter { $0.status == .done }) { r in Text(r.title).tag(r.id) }
            }
            Text(lab.inputText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                Text("Models").font(.system(size: 12, weight: .medium))
                ChipGrid {
                    chip(.apple)
                    ForEach(settings.config.labCleanupModels, id: \.self) { m in chip(.openrouter(m)) }
                    chip(.custom)
                }
                ModelListEditor(models: $settings.config.labCleanupModels, audioOnly: false,
                                placeholder: "Add an OpenRouter model")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompts").font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    ForEach(Lab.PromptChoice.allCases) { p in
                        Chip(label: p.label, on: lab.prompts.contains(p)) {
                            if lab.prompts.contains(p) { lab.prompts.remove(p) } else { lab.prompts.insert(p) }
                        }
                        .disabled(p == .mine && settings.config.cleanupCustomPrompt.isEmpty)
                    }
                    Spacer()
                    Button(editingPrompt ? "Done" : "Edit Lab prompt") {
                        if settings.config.labPrompt.isEmpty { settings.config.labPrompt = RustCore.promptInfo.defaultTemplate }
                        withAnimation { editingPrompt.toggle() }
                    }
                    .controlSize(.small)
                }
                if editingPrompt {
                    PromptEditor(prompt: $settings.config.labPrompt, hasVocabulary: !settings.config.vocabulary.isEmpty,
                                 preview: { previewLabPrompt })
                }
            }

            HStack(spacing: 10) {
                Toggle("Judge each result with", isOn: $lab.judge)
                TextField("", text: $settings.config.labJudgeModel)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 260)
                    .disabled(!lab.judge)
            }
            .font(.system(size: 12))

            HStack {
                RunButton(title: "Polish", running: lab.polishing,
                          disabled: lab.polishers.isEmpty || lab.prompts.isEmpty || lab.inputText.isEmpty) {
                    Task { await lab.polish() }
                }
                Text("\(lab.polishers.count * lab.prompts.count) runs. Remote models run in parallel; Apple Intelligence runs alone.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let best = lab.bestPick, !lab.polishing {
                Label {
                    Text("Fastest\(best.score != nil ? " scoring 8+" : ""): **\(best.title)** · \(best.detail) · \(seconds(best.seconds))")
                } icon: { Image(systemName: "trophy.fill").foregroundStyle(.yellow) }
                .font(.system(size: 12.5))
            }
            ForEach(lab.cleanResults.sorted(by: rank)) { r in
                ResultCard(result: r, pickable: false, picked: false) {}
            }
        } header: {
            Text("2 · Polish")
        }
    }

    private var previewLabPrompt: String {
        var cfg = PipelineConfig.current(appName: settings.config.cleanupUsesAppContext ? lab.entry?.appName ?? "Slack" : nil)
        cfg.cleanupCustomPrompt = settings.config.labPrompt
        return RustCore.cleanupSystemPrompt(cfg.promptContext(withAudio: false))
    }

    private func chip(_ p: Lab.Polisher) -> some View {
        Chip(label: p.label, on: lab.polishers.contains(p)) {
            if lab.polishers.contains(p) { lab.polishers.remove(p) } else { lab.polishers.insert(p) }
        }
    }

    /// Finished results fastest-first; failures last.
    private func rank(_ a: Lab.Result, _ b: Lab.Result) -> Bool {
        (a.seconds ?? .infinity) < (b.seconds ?? .infinity)
    }
}

// MARK: - Pieces

private func seconds(_ s: Double?) -> String {
    guard let s else { return "—" }
    return s < 10 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
}

private struct Chip: View {
    var label: String
    var on: Bool
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                Text(label).font(.system(size: 11.5)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05)))
            .foregroundStyle(on ? Theme.accent : Color.primary)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

private struct ChipGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            content
        }
    }
}

/// Add / remove OpenRouter model ids for the Lab, with the usual model picker.
private struct ModelListEditor: View {
    @Binding var models: [String]
    var audioOnly: Bool
    var placeholder: String
    @ViewState private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(placeholder).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize()
            ModelField(model: $draft, provider: {
                RemoteProvider(kind: .openrouter, baseUrl: nil, apiKey: Keychain.get(.openrouter), model: "")
            }, audioOnly: audioOnly)
            Button("Add") {
                let m = draft.trimmingCharacters(in: .whitespaces)
                if !m.isEmpty && !models.contains(m) { models.append(m) }
                draft = ""
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            Menu {
                ForEach(models, id: \.self) { m in
                    Button(m, role: .destructive) { models.removeAll { $0 == m } }
                }
            } label: { Image(systemName: "minus.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Remove a model from this list")
            .disabled(models.isEmpty)
        }
        .help(placeholder)
    }
}

private struct RunButton: View {
    var title: String
    var running: Bool
    var disabled: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                Text(title)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(running || disabled)
    }
}

private struct ResultCard: View {
    var result: Lab.Result
    var pickable: Bool
    var picked: Bool
    var onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if pickable {
                    Button(action: onPick) {
                        Image(systemName: picked ? "largecircle.fill.circle" : "circle").foregroundStyle(picked ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain).help("Use this transcript as the cleanup input")
                }
                Text(result.title).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).lineLimit(1)
                if !result.detail.isEmpty {
                    Text(result.detail).font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Spacer()
                badges
            }
            switch result.status {
            case .running:
                ProgressView().controlSize(.small)
            case .failed(let why):
                Text(why).font(.system(size: 11.5)).foregroundStyle(.red).textSelection(.enabled)
            case .done:
                Text(result.text.isEmpty ? "(empty)" : result.text).font(.system(size: 12.5)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let n = result.notes, !n.isEmpty {
                    Text(n).font(.system(size: 11)).foregroundStyle(.secondary).italic()
                }
                if let j = result.judgeError {
                    Text("Judge: \(j)").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(picked ? Theme.accent.opacity(0.07) : Color.primary.opacity(0.03)))
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 6) {
            if let s = result.score {
                Text(String(format: "%.0f/10", s))
                    .font(.system(size: 11, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(scoreColor(s).opacity(0.18)))
                    .foregroundStyle(scoreColor(s))
            }
            if let u = result.usage {
                if let cost = u.cost {
                    Text(cost * 1000 < 0.01 ? "<$0.01 / 1k" : String(format: "$%.2f / 1k", cost * 1000))
                        .help(String(format: "$%.6f for this run", cost))
                }
                if let p = u.promptTokens, let c = u.completionTokens { Text("\(p)+\(c) tok") }
            }
            if let s = result.seconds {
                Text(seconds(s)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func scoreColor(_ s: Double) -> Color { s >= 8 ? .green : s >= 6 ? .orange : .red }
}
