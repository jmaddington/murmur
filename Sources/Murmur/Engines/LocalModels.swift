@preconcurrency import AVFAudio
import CoreML
import Darwin
import FluidAudio
import Foundation

// MARK: - Catalog

/// Open-weight speech models Murmur can download and run on this Mac.
enum LocalModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeetV3, parakeetV2, voxtral

    var id: String { rawValue }

    enum Runtime { case coreML, mlx }
    var runtime: Runtime { self == .voxtral ? .mlx : .coreML }

    var label: String {
        switch self {
        case .parakeetV3: "Parakeet v3"
        case .parakeetV2: "Parakeet v2"
        case .voxtral: "Voxtral Realtime"
        }
    }

    var vendor: String {
        switch self {
        case .parakeetV3, .parakeetV2: "NVIDIA · 0.6B"
        case .voxtral: "Mistral · 4B"
        }
    }

    var detail: String {
        switch self {
        case .parakeetV3: "Top-tier accuracy, transcribes in a blink on the Neural Engine. 25 European languages."
        case .parakeetV2: "English-only sibling of v3; slightly more accurate on English."
        case .voxtral: "Mistral's speech LLM: strong on names, punctuation and 13 languages. Runs on the GPU via MLX; needs ~4 GB of free memory."
        }
    }

    var downloadSize: String {
        switch self {
        case .parakeetV3, .parakeetV2: "≈ 0.5 GB"
        case .voxtral: "≈ 3.6 GB"
        }
    }

    var symbol: String { runtime == .coreML ? "bird" : "wind" }

    /// Hugging Face repo for MLX models.
    var mlxRepo: String? { self == .voxtral ? "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit" : nil }
    /// Approximate model bytes, for download progress.
    var mlxBytes: Double { 3.15e9 }

    var parakeetVersion: AsrModelVersion? {
        switch self {
        case .parakeetV3: .v3
        case .parakeetV2: .v2
        case .voxtral: nil
        }
    }

    /// Below this much RAM the model works but is noticeably slow.
    var comfortableRAM: UInt64 { runtime == .mlx ? 16 << 30 : 0 }
}

enum LocalModelError: LocalizedError {
    case notInstalled(LocalModel)
    case setup(String)
    case worker(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let m): "\(m.label) isn't downloaded yet. Open Settings → Transcription to download it."
        case .setup(let s): s
        case .worker(let s): s
        }
    }
}

enum LocalPaths {
    static var base: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func parakeet(_ v: AsrModelVersion) -> URL {
        base.appendingPathComponent("parakeet", isDirectory: true)
            .appendingPathComponent(AsrModels.defaultCacheDirectory(for: v).lastPathComponent, isDirectory: true)
    }

    static var mlx: URL { base.appendingPathComponent("mlx", isDirectory: true) }
    static var mlxEnv: URL { mlx.appendingPathComponent("env", isDirectory: true) }
    static var mlxPython: URL { mlxEnv.appendingPathComponent("bin/python3") }
    static var hfHome: URL { base.appendingPathComponent("hf", isDirectory: true) }
    static func mlxModelMarker(_ m: LocalModel) -> URL { mlx.appendingPathComponent("\(m.rawValue).ready") }
    static var mlxEnvMarker: URL { mlxEnv.appendingPathComponent(".murmur-ready-\(MLXRuntime.packageSpec)") }

    static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

// MARK: - Store (install / remove / status)

@MainActor @Observable
final class LocalModelStore {
    static let shared = LocalModelStore()

    enum State: Equatable {
        case notInstalled
        case installing(progress: Double, step: String)
        case ready
        case failed(String)
    }

    private(set) var states: [LocalModel: State] = [:]
    private var tasks: [LocalModel: Task<Void, Never>] = [:]

    private init() { refresh() }

    func state(_ m: LocalModel) -> State { states[m] ?? .notInstalled }

    nonisolated static func isInstalled(_ m: LocalModel) -> Bool {
        switch m.runtime {
        case .coreML:
            return AsrModels.modelsExist(at: LocalPaths.parakeet(m.parakeetVersion!), version: m.parakeetVersion!)
        case .mlx:
            let fm = FileManager.default
            return fm.fileExists(atPath: LocalPaths.mlxEnvMarker.path) && fm.fileExists(atPath: LocalPaths.mlxModelMarker(m).path)
        }
    }

    func refresh() {
        for m in LocalModel.allCases {
            if case .installing = state(m) { continue }
            states[m] = Self.isInstalled(m) ? .ready : .notInstalled
        }
    }

    func install(_ m: LocalModel) {
        guard tasks[m] == nil else { return }
        states[m] = .installing(progress: 0, step: "Starting…")
        tasks[m] = Task {
            do {
                switch m.runtime {
                case .coreML: try await installParakeet(m)
                case .mlx: try await MLXRuntime.install(m) { p, step in
                    Task { @MainActor in self.states[m] = .installing(progress: p, step: step) }
                }
                }
                states[m] = .ready
            } catch is CancellationError {
                states[m] = Self.isInstalled(m) ? .ready : .notInstalled
            } catch {
                states[m] = .failed(error.localizedDescription)
            }
            tasks[m] = nil
        }
    }

    func cancelInstall(_ m: LocalModel) {
        tasks[m]?.cancel()
    }

    func remove(_ m: LocalModel) {
        switch m.runtime {
        case .coreML:
            Task { await ParakeetRuntime.shared.unload() }
            try? FileManager.default.removeItem(at: LocalPaths.parakeet(m.parakeetVersion!))
        case .mlx:
            Task { await MLXRuntime.shared.stop() }
            try? FileManager.default.removeItem(at: LocalPaths.mlxModelMarker(m))
            if let repo = m.mlxRepo {
                try? FileManager.default.removeItem(at: LocalPaths.hfHome.appendingPathComponent("hub/models--" + repo.replacingOccurrences(of: "/", with: "--")))
            }
            // Drop the Python runtime too once no MLX model needs it.
            if !LocalModel.allCases.contains(where: { $0.runtime == .mlx && $0 != m && Self.isInstalled($0) }) {
                try? FileManager.default.removeItem(at: LocalPaths.mlx)
            }
        }
        states[m] = .notInstalled
    }

    private func installParakeet(_ m: LocalModel) async throws {
        let v = m.parakeetVersion!
        let dir = LocalPaths.parakeet(v)
        _ = try await AsrModels.download(to: dir, version: v) { p in
            Task { @MainActor in
                LocalModelStore.shared.states[m] = .installing(progress: p.fractionCompleted * 0.9, step: "Downloading")
            }
        }
        states[m] = .installing(progress: 0.92, step: "Optimizing for the Neural Engine…")
        // First load compiles the Core ML graphs; do it now rather than on the first dictation.
        try await ParakeetRuntime.shared.manager(for: v)
    }

    var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
}

// MARK: - Parakeet (Core ML via FluidAudio)

actor ParakeetRuntime {
    static let shared = ParakeetRuntime()
    private var loaded: (version: AsrModelVersion, manager: AsrManager)?

    @discardableResult
    func manager(for v: AsrModelVersion) async throws -> AsrManager {
        if let loaded, loaded.version == v { return loaded.manager }
        let dir = LocalPaths.parakeet(v)
        guard AsrModels.modelsExist(at: dir, version: v) else {
            throw LocalModelError.notInstalled(v == .v2 ? .parakeetV2 : .parakeetV3)
        }
        let models = try await AsrModels.load(from: dir, version: v)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        loaded = (v, m)
        return m
    }

    func transcribe(_ samples: [Float], version: AsrModelVersion) async throws -> String {
        let m = try await manager(for: version)
        var state = try TdtDecoderState(decoderLayers: await m.decoderLayerCount)
        return try await m.transcribe(samples, decoderState: &state).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() { loaded = nil }
}

final class ParakeetSession: TranscriptionSession, @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    let supportsLivePreview = true

    private let version: AsrModelVersion
    private let lock = NSLock()
    private var samples: [Float] = []
    private var previewTask: Task<Void, Never>?
    private var cancelled = false

    init(model: LocalModel) {
        version = model.parakeetVersion ?? .v3
        // Load (or reuse) the model while the user is still talking.
        let v = version
        Task.detached(priority: .userInitiated) { _ = try? await ParakeetRuntime.shared.manager(for: v) }
        previewTask = Task.detached(priority: .utility) { [weak self] in await self?.previewLoop() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    /// Re-transcribe what's been said so far about once a second: Parakeet is
    /// fast enough on the Neural Engine that this gives a live preview.
    private func previewLoop() async {
        var lastCount = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(900))
            let snapshot = lock.withLock { cancelled ? nil : samples }
            guard let snapshot, snapshot.count >= 16_000, snapshot.count != lastCount else { continue }
            lastCount = snapshot.count
            guard let text = try? await ParakeetRuntime.shared.transcribe(snapshot, version: version),
                  !Task.isCancelled, !text.isEmpty else { continue }
            await MainActor.run { [weak self] in self?.onPartial?(text) }
        }
    }

    func finish(samples all: [Float]) async throws -> String {
        previewTask?.cancel()
        // Parakeet wants at least a second; pad short clips with silence.
        var audio = all
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        return try await ParakeetRuntime.shared.transcribe(audio, version: version)
    }

    func cancel() {
        lock.withLock { cancelled = true }
        previewTask?.cancel()
    }
}

// MARK: - MLX (Python worker managed with uv)

actor MLXRuntime {
    static let shared = MLXRuntime()
    /// Pinned so an upstream release can't break a working install.
    static let packageSpec = "mlx-audio==0.6.8"

    private var process: Process?
    private var model: LocalModel?
    private var input: FileHandle?
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator?

    // MARK: Install

    static func install(_ m: LocalModel, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: LocalPaths.mlx, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: LocalPaths.mlxEnvMarker.path) {
            progress(0.02, "Getting uv…")
            let uv = try await uvBinary()
            try Task.checkCancellation()
            progress(0.05, "Setting up Python…")
            try? fm.removeItem(at: LocalPaths.mlxEnv)
            try await run(uv, ["venv", "--quiet", "--python", "3.12", LocalPaths.mlxEnv.path])
            try Task.checkCancellation()
            progress(0.1, "Installing MLX…")
            try await run(uv, ["pip", "install", "--quiet", "--python", LocalPaths.mlxPython.path, packageSpec])
            fm.createFile(atPath: LocalPaths.mlxEnvMarker.path, contents: Data())
            // Wheels are installed; the download cache is dead weight.
            try? fm.removeItem(at: LocalPaths.mlx.appendingPathComponent("uv-cache"))
        }
        try Task.checkCancellation()
        progress(0.2, "Downloading \(m.label)…")
        let repoDir = LocalPaths.hfHome.appendingPathComponent("hub/models--" + m.mlxRepo!.replacingOccurrences(of: "/", with: "--"))
        let watcher = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let got = Double(LocalPaths.size(of: repoDir))
                progress(0.2 + 0.7 * min(1, got / m.mlxBytes), "Downloading \(m.label)…")
            }
        }
        defer { watcher.cancel() }
        await shared.stop()
        try await shared.request(["cmd": "download"], model: m, offline: false)
        watcher.cancel()
        progress(0.93, "Loading \(m.label)…")
        fm.createFile(atPath: LocalPaths.mlxModelMarker(m).path, contents: Data())
        await shared.stop()
        try await shared.request(["cmd": "load"], model: m)
    }

    /// A uv binary: an installed one, or a verified download into Murmur's folder.
    static func uvBinary() async throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ours = LocalPaths.mlx.appendingPathComponent("bin/uv")
        let forceDownload = ProcessInfo.processInfo.environment["MURMUR_FORCE_UV_DOWNLOAD"] == "1"
        for p in [ours.path, "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
        where FileManager.default.isExecutableFile(atPath: p) && !(forceDownload && p != ours.path) {
            return URL(fileURLWithPath: p)
        }
        let base = "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz"
        let (tarball, _) = try await URLSession.shared.download(from: URL(string: base)!)
        let (sumData, _) = try await URLSession.shared.data(from: URL(string: base + ".sha256")!)
        let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let actual = try await run(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", tarball.path])
            .split(separator: " ").first.map(String.init) ?? ""
        guard !expected.isEmpty, expected.lowercased() == actual.lowercased() else {
            throw LocalModelError.setup("The uv download failed its checksum.")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-uv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", tarball.path, "-C", tmp.path])
        try FileManager.default.createDirectory(at: ours.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: ours)
        try FileManager.default.moveItem(at: tmp.appendingPathComponent("uv-aarch64-apple-darwin/uv"), to: ours)
        return ours
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("PYTHON") || k.hasPrefix("VIRTUAL_ENV") || k.hasPrefix("CONDA") { env[k] = nil }
        env["UV_CACHE_DIR"] = LocalPaths.mlx.appendingPathComponent("uv-cache").path
        env["UV_PYTHON_INSTALL_DIR"] = LocalPaths.mlx.appendingPathComponent("python").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["HF_HOME"] = LocalPaths.hfHome.path
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        return env
    }

    @discardableResult
    static func run(_ exe: URL, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.environment = environment
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { p in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 { cont.resume(returning: o) }
                else {
                    let tail = e.split(separator: "\n").suffix(3).joined(separator: " ")
                    cont.resume(throwing: LocalModelError.setup("\(exe.lastPathComponent) \(args.first ?? "") failed: \(tail)"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: Worker

    private func start(_ m: LocalModel, offline: Bool) throws {
        if process?.isRunning == true, model == m { return }
        stop()
        guard let script = Bundle.main.url(forResource: "mlx_worker", withExtension: "py") else {
            throw LocalModelError.setup("mlx_worker.py is missing from the app bundle.")
        }
        guard FileManager.default.isExecutableFile(atPath: LocalPaths.mlxPython.path) else {
            throw LocalModelError.notInstalled(m)
        }
        let p = Process()
        p.executableURL = LocalPaths.mlxPython
        p.arguments = ["-I", "-u", script.path, m.mlxRepo!]
        var env = Self.environment
        if offline { env["HF_HUB_OFFLINE"] = "1" }
        p.environment = env
        p.currentDirectoryURL = LocalPaths.mlx
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        let log = LocalPaths.mlx.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: log)) ?? FileHandle.nullDevice
        try p.run()
        process = p
        model = m
        input = inPipe.fileHandleForWriting
        lines = outPipe.fileHandleForReading.bytes.lines.makeAsyncIterator()
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        model = nil
        input = nil
        lines = nil
    }

    private func readReply() async throws -> [String: Any] {
        while true {
            var it = lines
            let next = try await it?.next()
            lines = it
            guard let line = next else {
                let log = (try? String(contentsOf: LocalPaths.mlx.appendingPathComponent("worker.log"), encoding: .utf8)) ?? ""
                let tail = log.split(separator: "\n").suffix(2).joined(separator: " ")
                stop()
                throw LocalModelError.worker("The MLX worker exited. \(tail)")
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if obj["ready"] != nil { continue }
            if let e = obj["error"] as? String { throw LocalModelError.worker(e) }
            return obj
        }
    }

    private var busy = false

    /// One request at a time: replies are matched to requests by order.
    @discardableResult
    func request(_ req: [String: Any], model m: LocalModel, offline: Bool = true) async throws -> [String: Any] {
        while busy { try await Task.sleep(for: .milliseconds(20)) }
        busy = true
        defer { busy = false }
        try start(m, offline: offline)
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(0x0A)
        try input?.write(contentsOf: data)
        return try await readReply()
    }

    func preload(_ m: LocalModel) async {
        guard LocalModelStore.isInstalled(m) else { return }
        _ = try? await request(["cmd": "load"], model: m)
    }

    func transcribe(wav: URL, model m: LocalModel) async throws -> String {
        guard LocalModelStore.isInstalled(m) else { throw LocalModelError.notInstalled(m) }
        let r = try await request(["cmd": "transcribe", "wav": wav.path], model: m)
        return (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class MLXSession: TranscriptionSession {
    var onPartial: ((String) -> Void)?
    let supportsLivePreview = false
    let model: LocalModel

    init(model: LocalModel) {
        self.model = model
        Task.detached(priority: .userInitiated) { await MLXRuntime.shared.preload(model) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).wav")
        try RustCore.writeWAV(samples, sampleRate: 16_000, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        return try await MLXRuntime.shared.transcribe(wav: wav, model: model)
    }

    func cancel() {}
}
