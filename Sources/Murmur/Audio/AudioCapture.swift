@preconcurrency import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

/// Everything downstream consumes 16 kHz mono Float32.
let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

protocol AudioSource: AnyObject {
    /// Called on a background thread with 16 kHz mono buffers.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    /// Normalised 0...1 level, called on a background thread.
    var onLevel: ((Float) -> Void)? { get set }
    /// Called (background thread) if the source dies mid-recording, e.g. mic unplugged.
    var onFailure: ((Error) -> Void)? { get set }
    var deviceName: String? { get }
    /// True once at least one buffer has arrived from the hardware.
    var hasReceivedAudio: Bool { get }
    func start(recordingTo url: URL?) throws
    /// Stops capture and returns every sample captured.
    func stop() -> [Float]
}

struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Shared conversion / accumulation / file-writing logic.
class CaptureSink {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var buffersIn = 0

    var hasReceivedAudio: Bool {
        lock.lock(); defer { lock.unlock() }
        return buffersIn > 0
    }

    func begin(inputFormat: AVAudioFormat, recordingTo url: URL?) throws {
        guard let conv = AVAudioConverter(from: inputFormat, to: speechFormat) else {
            throw CaptureError(message: "Unsupported input format \(inputFormat)")
        }
        // Mix all channels down rather than taking only the first.
        if inputFormat.channelCount > 1 { conv.downmix = true }
        converter = conv
        buffersIn = 0
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 60)
        if let url {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        // `finish()` clears the converter from another thread while a tap
        // callback (or the FileSource task) can still be mid-flight: take a
        // strong reference under the lock instead of racing on the property.
        lock.lock()
        buffersIn += 1
        let converter = self.converter
        lock.unlock()
        guard let converter else { return }
        let ratio = speechFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: ch, count: n)

        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-7))
        let level = min(max((db + 55) / 40, 0), 1)

        lock.lock()
        samples.append(contentsOf: chunk)
        try? file?.write(from: out)
        lock.unlock()

        onLevel?(level)
        onBuffer?(out)
    }

    func finish() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        file = nil // closes & finalises the AAC file
        converter = nil
        return samples
    }
}

/// Live microphone capture via AVAudioEngine bound to a specific CoreAudio device.
final class MicrophoneSource: CaptureSink, AudioSource {
    private var engine: AVAudioEngine?
    private let device: InputDevice?
    private var configObserver: NSObjectProtocol?
    var deviceName: String? { device?.name }

    init(device: InputDevice?) {
        self.device = device
    }

    func start(recordingTo url: URL?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device, let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                throw CaptureError(message: "Couldn't open \(device.name) (\(status))")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError(message: "\(device?.name ?? "Microphone") has no usable input")
        }
        try begin(inputFormat: format, recordingTo: url)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.ingest(buf)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            // Main queue: `engine` is only ever touched there (start/stop).
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, let engine = self.engine, !engine.isRunning else { return }
            self.onFailure?(CaptureError(message: "\(self.deviceName ?? "Microphone") disconnected"))
        }
    }

    func stop() -> [Float] {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        return finish()
    }
}

/// Plays an audio file through the pipeline as if it were a microphone.
/// Used by the end-to-end test harness and by "Re-transcribe" in History.
final class FileSource: CaptureSink, AudioSource {
    private let url: URL
    private let realtime: Bool
    private var task: Task<Void, Never>?
    var deviceName: String? { "File: \(url.lastPathComponent)" }
    /// Fires once the whole file has been delivered.
    var onEnd: (() -> Void)?

    init(url: URL, realtime: Bool) {
        self.url = url
        self.realtime = realtime
    }

    func start(recordingTo dest: URL?) throws {
        let file = try AVAudioFile(forReading: url)
        try begin(inputFormat: file.processingFormat, recordingTo: dest)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10) // 100 ms
        let realtime = self.realtime
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                do { try file.read(into: buf, frameCount: chunk) } catch { break }
                if buf.frameLength == 0 { break }
                self?.ingest(buf)
                if realtime { try? await Task.sleep(for: .milliseconds(100)) }
            }
            self?.onEnd?()
        }
    }

    func waitUntilDone() async { await task?.value }

    func stop() -> [Float] {
        task?.cancel()
        return finish()
    }
}

/// Decode any audio file to 16 kHz mono samples.
func loadSpeechSamples(from url: URL) throws -> [Float] {
    let src = FileSource(url: url, realtime: false)
    var done = false
    let sem = DispatchSemaphore(value: 0)
    src.onEnd = { done = true; sem.signal() }
    try src.start(recordingTo: nil)
    sem.wait()
    _ = done
    return src.stop()
}
