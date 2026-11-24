import AVFAudio
import SwiftUI

struct LabPane: View {
    @Bindable var lab = Lab.shared
    @Bindable var settings = AppSettings.shared
    var history = HistoryStore.shared
    var store = LocalModelStore.shared
    @ViewState private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: Pane.lab.symbol, color: Pane.lab.color, title: "Lab",
                       subtitle: "Replay real recordings through other models and prompts. Find the fastest setup that still nails it.")
            Picker("", selection: $mode) {
                Text("Eval · all recordings").tag(0)
                Text("One recording").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360).padding(.bottom, 4)
            if mode == 0 { EvalView(settings: settings, store: store) } else { single }
        }
        .onAppear { store.refresh() }
    }

    private var single: some View {
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

func seconds(_ s: Double?) -> String {
    guard let s else { return "—" }
    return s < 10 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
}

struct Chip: View {
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

struct ChipGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            content
        }
    }
}

/// Add / remove OpenRouter model ids for the Lab, with the usual model picker.
struct ModelListEditor: View {
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

struct RunButton: View {
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

// MARK: - Eval (all recordings × pipelines)

struct EvalView: View {
    @Bindable var settings: AppSettings
    var store: LocalModelStore
    @Bindable var eval = LabEval.shared
    var history = HistoryStore.shared
    @ViewState private var sort = 0
    @ViewState private var expanded: String?

    var body: some View {
        Form {
            recordingsSection
            pipelinesSection
            judgeSection
            runSection
            if let run = eval.current { EvalResults(run: run, eval: eval, sort: $sort, expanded: $expanded) }
        }
        .formStyle(.grouped)
    }

    private var recordingsSection: some View {
        Section {
            if eval.recordings.isEmpty {
                Text("No recordings with saved audio yet. Murmur keeps audio for the period set in History → Retention.")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup {
                    ForEach(eval.recordings) { e in
                        Toggle(isOn: Binding(get: { !eval.excluded.contains(e.id) },
                                             set: { on in if on { eval.excluded.remove(e.id) } else { eval.excluded.insert(e.id) } })) {
                            HStack {
                                Text(LabEval.title(e)).lineLimit(1)
                                Spacer()
                                Text(e.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .foregroundStyle(.secondary).font(.system(size: 11))
                            }
                        }
                    }
                    HStack {
                        Button("All") { eval.excluded = [] }
                        Button("None") { eval.excluded = Set(eval.recordings.map(\.id)) }
                    }
                    .controlSize(.small)
                } label: {
                    let total = eval.selected.reduce(0) { $0 + $1.duration }
                    Text("\(eval.selected.count) of \(eval.recordings.count) recordings · \(HUDView.clock(total)) of audio")
                }
            }
        } header: { Text("Recordings") }
    }

    private var pipelinesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speech engines").font(.system(size: 12, weight: .medium))
                ChipGrid {
                    ForEach(AppleSpeechModel.allCases) { m in sttChip(.apple(m)) }
                    ForEach(LocalModel.allCases.filter { store.state($0) == .ready }) { m in sttChip(.local(m)) }
                    ForEach(settings.config.labTranscribeModels, id: \.self) { m in sttChip(.openrouter(m)) }
                    sttChip(.custom)
                }
                ModelListEditor(models: $settings.config.labTranscribeModels, audioOnly: true, placeholder: "Add an OpenRouter audio model")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Cleanup").font(.system(size: 12, weight: .medium))
                ChipGrid {
                    Chip(label: "No cleanup", on: eval.includeRaw) { eval.includeRaw.toggle() }
                    polChip(.apple)
                    ForEach(settings.config.labCleanupModels, id: \.self) { m in polChip(.openrouter(m)) }
                    polChip(.custom)
                }
                ModelListEditor(models: $settings.config.labCleanupModels, audioOnly: false, placeholder: "Add an OpenRouter model")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Prompts").font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    ForEach(Lab.PromptChoice.allCases) { p in
                        Chip(label: p.label, on: eval.prompts.contains(p)) {
                            if eval.prompts.contains(p) { eval.prompts.remove(p) } else { eval.prompts.insert(p) }
                        }
                        .disabled((p == .mine && settings.config.cleanupCustomPrompt.isEmpty) || (p == .lab && settings.config.labPrompt.isEmpty))
                    }
                }
                Text("“My prompt” is your Cleanup prompt; edit the “Lab prompt” in One recording mode.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: { Text("Pipelines") }
    }

    private var judgeSection: some View {
        Section {
            Toggle("Score every result with a judge model", isOn: $eval.judge)
            if eval.judge {
                Picker("Judge", selection: $eval.judgeListens) {
                    Text("Listens to the recording").tag(true)
                    Text("Reads a reference transcript").tag(false)
                }
                if eval.judgeListens {
                    LabeledContent("Audio model") {
                        TextField("", text: $settings.config.labListenJudgeModel).textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Text("Hears what you actually said and grades the final text end to end. Needs an audio-capable model.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Model") {
                        TextField("", text: $settings.config.labJudgeModel).textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Picker("Reference transcript", selection: $settings.config.labReferenceSTT) {
                        ForEach(referenceChoices, id: \.id) { Text($0.label).tag($0.id) }
                    }
                }
            }
        } header: { Text("Judge") }
    }

    private var referenceChoices: [Lab.STT] {
        AppleSpeechModel.allCases.map { Lab.STT.apple($0) }
            + LocalModel.allCases.filter { store.state($0) == .ready }.map { Lab.STT.local($0) }
            + settings.config.labTranscribeModels.map { Lab.STT.openrouter($0) }
    }

    private var runSection: some View {
        Section {
            let pipes = eval.pipelines.count
            let runs = pipes * eval.selected.count
            HStack(spacing: 10) {
                if eval.running {
                    Button("Stop") { eval.cancel() }
                    ProgressView(value: Double(eval.done), total: Double(max(eval.total, 1))).frame(maxWidth: 240)
                    Text("\(eval.done)/\(eval.total)").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    RunButton(title: "Run eval", running: false, disabled: runs == 0 || eval.excluded.count == eval.recordings.count) { eval.start() }
                    Text("\(pipes) pipelines × \(eval.selected.count) recordings = \(runs) results. Transcripts are cached, so re-runs only pay for cleanup.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sttChip(_ s: Lab.STT) -> some View {
        Chip(label: s.label, on: eval.sttChoices.contains(s)) {
            if eval.sttChoices.contains(s) { eval.sttChoices.remove(s) } else { eval.sttChoices.insert(s) }
        }
    }

    private func polChip(_ p: Lab.Polisher) -> some View {
        Chip(label: p.label, on: eval.polishers.contains(p)) {
            if eval.polishers.contains(p) { eval.polishers.remove(p) } else { eval.polishers.insert(p) }
        }
    }
}

private struct EvalResults: View {
    var run: EvalRun
    var eval: LabEval
    @Binding var sort: Int
    @Binding var expanded: String?

    var body: some View {
        Section {
            HStack {
                Picker("Run", selection: Binding(get: { run.id }, set: { id in eval.current = eval.runs.first { $0.id == id } })) {
                    ForEach(eval.runs) { r in
                        Text("\(r.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(r.recordingIDs.count) rec × \(r.pipelines.count)").tag(r.id)
                    }
                    if !eval.runs.contains(where: { $0.id == run.id }) { Text("Current").tag(run.id) }
                }
                .frame(maxWidth: 320)
                Spacer()
                Picker("", selection: $sort) {
                    Text("Best score").tag(0)
                    Text("Fastest").tag(1)
                    Text("Cheapest").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 250)
                Menu {
                    Button("Export CSV…") { export() }
                    Button("Delete run", role: .destructive) { eval.deleteRun(run) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let best = eval.best(run) {
                let l = LabEval.label(best.pipeline)
                Label {
                    Text("Fastest\(best.score != nil ? " averaging 8+" : ""): **\(l.stt)** → **\(l.cleanup)** · \(seconds(best.totalSeconds))\(best.score.map { String(format: " · %.1f/10", $0) } ?? "")")
                } icon: { Image(systemName: "trophy.fill").foregroundStyle(.yellow) }
                .font(.system(size: 12.5))
            }
            EvalHeaderRow()
            ForEach(sorted(eval.rows(run))) { row in
                EvalRowView(row: row, open: expanded == row.id) { expanded = expanded == row.id ? nil : row.id }
                if expanded == row.id {
                    ForEach(run.cells.filter { $0.pipelineID == row.id }) { c in EvalCellView(cell: c, eval: eval) }
                }
            }
        } header: { Text("Results") }
    }

    private func sorted(_ rows: [EvalRow]) -> [EvalRow] {
        switch sort {
        case 1: rows.sorted { ($0.totalSeconds ?? .infinity) < ($1.totalSeconds ?? .infinity) }
        case 2: rows.sorted { ($0.costPer1k ?? 0) < ($1.costPer1k ?? 0) }
        default: rows.sorted { ($0.score ?? -1, -($0.totalSeconds ?? .infinity)) > ($1.score ?? -1, -($1.totalSeconds ?? .infinity)) }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "murmur-eval-\(run.date.formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? eval.csv(run).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct EvalHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Speech → Cleanup").frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text("Score")
                Text("Speech")
                Text("Cleanup")
                Text("Total")
                Text("$ / 1k")
            }
            .frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
    }
}

private struct EvalRowView: View {
    var row: EvalRow
    var open: Bool
    var toggle: () -> Void

    var body: some View {
        let l = LabEval.label(row.pipeline)
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.stt).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(l.cleanup + (row.failures > 0 ? " · \(row.failures) failed" : ""))
                        .font(.system(size: 11)).foregroundStyle(row.failures > 0 ? Color.orange : Color.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    Text(row.score.map { String(format: "%.1f", $0) } ?? "—")
                        .foregroundStyle(row.score.map { $0 >= 8 ? Color.green : $0 >= 6 ? Color.orange : Color.red } ?? Color.secondary)
                        .fontWeight(.bold)
                    Text(seconds(row.sttSeconds))
                    Text(row.pipeline.polisher == nil ? "—" : seconds(row.cleanSeconds))
                    Text(seconds(row.totalSeconds)).fontWeight(.semibold)
                    Text(row.costPer1k.map { $0 < 0.01 ? "<0.01" : String(format: "%.2f", $0) } ?? "—")
                }
                .frame(width: 58, alignment: .trailing)
                .monospacedDigit()
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EvalCellView: View {
    var cell: EvalCell
    var eval: LabEval

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(eval.recording(cell.recordingID).map(LabEval.title) ?? "Deleted recording")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let s = cell.score { Text(String(format: "%.0f/10", s)).font(.system(size: 11, weight: .bold)) }
                Text(seconds(cell.totalSeconds)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let e = cell.error {
                Text(e).font(.system(size: 11.5)).foregroundStyle(.red)
            } else {
                Text(cell.text ?? "").font(.system(size: 12)).textSelection(.enabled)
                if let n = cell.notes, !n.isEmpty { Text(n).font(.system(size: 11)).italic().foregroundStyle(.secondary) }
            }
        }
        .padding(.leading, 18).padding(.vertical, 2)
    }
}
