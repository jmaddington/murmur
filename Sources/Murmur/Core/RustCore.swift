import CMurmurCore
import Foundation

/// Thin, typed wrapper over the Rust core's JSON dispatcher.
enum RustCore {
    struct CoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Empty: Codable {}

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private struct Envelope<R: Decodable>: Decodable {
        let ok: R?
        let error: String?
    }

    /// Synchronous call. May block on network I/O for remote commands.
    static func call<A: Encodable, R: Decodable>(_ cmd: String, _ args: A, as _: R.Type = R.self) throws -> R {
        guard var obj = try JSONSerialization.jsonObject(with: encoder.encode(args)) as? [String: Any] else {
            throw CoreError(message: "arguments must encode to an object")
        }
        obj["cmd"] = cmd
        let request = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        guard let ptr = request.withCString({ murmur_call($0) }) else {
            throw CoreError(message: "core returned null")
        }
        defer { murmur_free(ptr) }
        let env = try decoder.decode(Envelope<R>.self, from: Data(String(cString: ptr).utf8))
        if let error = env.error { throw CoreError(message: error) }
        guard let ok = env.ok else { throw CoreError(message: "empty response") }
        return ok
    }

    /// Off-main-thread variant for anything that may touch the network or disk.
    static func callAsync<A: Encodable & Sendable, R: Decodable & Sendable>(_ cmd: String, _ args: A, as _: R.Type = R.self) async throws -> R {
        try await Task.detached(priority: .userInitiated) {
            try call(cmd, args, as: R.self)
        }.value
    }

    static func writeWAV(_ samples: [Float], sampleRate: UInt32, to url: URL) throws {
        let rc = samples.withUnsafeBufferPointer { buf in
            url.path.withCString { murmur_write_wav(buf.baseAddress, buf.count, sampleRate, $0) }
        }
        if rc != 0 { throw CoreError(message: "could not write WAV (\(rc))") }
    }

    // MARK: Typed helpers

    struct TextResult: Codable, Sendable { let text: String }
    struct PromptResult: Codable, Sendable { let prompt: String }

    static func applyVocabulary(_ text: String, _ vocab: [VocabTerm]) -> String {
        struct A: Encodable { let text: String; let vocabulary: [VocabTerm] }
        return (try? call("apply_vocabulary", A(text: text, vocabulary: vocab), as: TextResult.self).text) ?? text
    }

    /// Everything a cleanup prompt template can draw on.
    struct PromptContext: Encodable, Sendable {
        var vocabulary: [VocabTerm]
        var style: String
        var appName: String?
        var withAudio: Bool
        var customPrompt: String?
        var date: String?
        var time: String?
    }

    struct PromptPlaceholder: Codable, Sendable, Hashable { let name: String; let description: String }
    struct PromptInfo: Codable, Sendable { let defaultTemplate: String; let placeholders: [PromptPlaceholder] }

    static func cleanupSystemPrompt(_ ctx: PromptContext) -> String {
        (try? call("cleanup_system_prompt", ctx, as: PromptResult.self).prompt) ?? ""
    }

    /// The built-in template and the placeholders custom prompts may use.
    static let promptInfo: PromptInfo = {
        struct A: Encodable {}
        return (try? call("cleanup_prompt_info", A(), as: PromptInfo.self)) ?? PromptInfo(defaultTemplate: "", placeholders: [])
    }()

    static func cleanupUserPrompt(_ text: String) -> String {
        struct A: Encodable { let text: String }
        return (try? call("cleanup_user_prompt", A(text: text), as: PromptResult.self).prompt) ?? text
    }

    static func sanitize(_ text: String) -> String {
        struct A: Encodable { let text: String }
        return (try? call("sanitize_llm_output", A(text: text), as: TextResult.self).text) ?? text
    }
}

/// Mirrors `llm::Provider` in Rust.
struct RemoteProvider: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case openrouter, openaiCompatible = "openai_compatible" }
    var kind: Kind
    var baseUrl: String?
    var apiKey: String?
    var model: String
}

struct RemoteModel: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let audioInput: Bool
}

extension RustCore {
    static func listModels(_ provider: RemoteProvider) async throws -> [RemoteModel] {
        struct R: Codable, Sendable { let models: [RemoteModel] }
        return try await callAsync("list_models", provider, as: R.self).models
    }
}
