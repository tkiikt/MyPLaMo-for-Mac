import Foundation
import Combine
import Darwin

enum TranslationError: LocalizedError {
    case invalidInput(String), engineMissing, startup(String), server(String), truncated, emptyResult
    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .startup(let message), .server(let message): return message
        case .engineMissing: return "翻訳エンジンが見つかりません。アプリを再インストールしてください。"
        case .truncated: return "訳文が出力上限に達しました。原文を短く分けて翻訳してください。表示中の訳文は未完です。"
        case .emptyResult: return "訳文が生成されませんでした。言語設定と原文を確認してください。"
        }
    }
}

struct PromptBuilder {
    static let maximumCharacters = 6000
    static let languageCodes: Set<String> = Set("ja en zh-hans zh-hant ko ar az be bg bn ca ceb de es et eu fa fr gu he hi hr hu hy id it jv ka kk km lt lv ml mr ms my ne nl pa pl ru si sk sl sr sw ta te th tl ur uz vi".split(separator: " ").map(String.init))

    static func make(text: String, source: String? = nil, target: String, style: String? = nil) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalidInput("翻訳する文章を入力してください。")
        }
        guard text.count <= maximumCharacters else {
            throw TranslationError.invalidInput("一度に翻訳できる原文は \(maximumCharacters) 文字までです。文章を分けてください。")
        }
        guard languageCodes.contains(target), source == nil || languageCodes.contains(source!) else {
            throw TranslationError.invalidInput("対応していない言語が選択されています。")
        }
        guard style == nil || ["plain", "polite"].contains(style!) else {
            throw TranslationError.invalidInput("文体の指定を確認してください。")
        }
        // Do not allow source text to introduce PFML control elements.
        guard !text.contains("<|plamo:") else {
            throw TranslationError.invalidInput("原文にモデルの制御記号が含まれています。記号を取り除いてください。")
        }
        var prompt = "<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input"
        if let source { prompt += "<|plamo:key|>lang<|plamo:val|>\(source)" }
        prompt += "<|plamo:msg|>\(text)<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>\(target)"
        if target == "ja", let style { prompt += "<|plamo:key|>form<|plamo:val|>\(style)" }
        return prompt + "<|plamo:msg|>"
    }
}

@MainActor
final class InferenceEngine: ObservableObject {
    @Published private(set) var status = "モデル未読み込み"
    @Published private(set) var isBusy = false
    @Published private(set) var output = ""
    private var process: Process?
    private var logHandle: FileHandle?
    private var loadedConfiguration: String?
    private var port = 0
    private var apiKey = ""
    private var session: URLSession?
    private var generation = UUID()

    func translate(text: String, source: String? = nil, target: String, style: String? = nil, modelURL: URL, useGPU: Bool) async throws -> String {
        guard !isBusy else { throw TranslationError.invalidInput("翻訳が終わるまでお待ちください。") }
        let prompt = try PromptBuilder.make(text: text, source: source, target: target, style: style)
        let operation = UUID()
        generation = operation
        isBusy = true
        output = ""
        defer { if generation == operation { isBusy = false } }
        do {
            try await ensureLoaded(modelURL: modelURL, useGPU: useGPU, operation: operation)
            try checkOperation(operation)
            status = "翻訳中…"
            let tokens = try await jsonRequest(path: "/tokenize", body: ["content": prompt, "add_special": true])
            try checkOperation(operation)
            guard let tokenList = tokens["tokens"] as? [Any] else { throw TranslationError.server("入力の長さを確認できませんでした。") }
            guard tokenList.count <= 8000 else { throw TranslationError.invalidInput("原文がモデルの入力上限を超えています。短く分けてください。") }
            var request = makeRequest(path: "/v1/completions")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "plamo-3-translate", "prompt": prompt, "temperature": 0, "max_tokens": 8192, "stream": true, "stop": ["<|plamo:tag|>", "<|plamo:bos|>"]])
            guard let session else { throw CancellationError() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw TranslationError.server("翻訳エンジンがリクエストを受け付けませんでした。")
            }
            var finished = false
            for try await line in bytes.lines {
                try checkOperation(operation)
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8), let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let error = item["error"] as? [String: Any] { throw TranslationError.server(error["message"] as? String ?? "翻訳に失敗しました。") }
                guard let choices = item["choices"] as? [[String: Any]], let choice = choices.first else { continue }
                if let text = choice["text"] as? String { output += text }
                if let reason = choice["finish_reason"] as? String {
                    if reason == "length" { throw TranslationError.truncated }
                    finished = reason == "stop"
                }
            }
            try checkOperation(operation)
            guard finished else { throw TranslationError.server("翻訳との接続が途中で終了しました。表示中の訳文は未完です。") }
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw TranslationError.emptyResult }
            status = useGPU ? "準備完了 · GPU" : "準備完了 · CPU"
            return output
        } catch {
            if generation == operation {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    stopProcess()
                    session?.invalidateAndCancel()
                    session = nil
                    status = "キャンセルしました"
                } else {
                    status = "翻訳できませんでした"
                }
            }
            throw error
        }
    }

    func cancel() {
        generation = UUID()
        session?.invalidateAndCancel()
        session = nil
        // Terminating the worker guarantees that cancelled GPU inference stops too.
        stopProcess()
        isBusy = false
        status = "キャンセルしました"
    }

    func shutdown() {
        cancel()
        status = "モデル未読み込み"
    }

    private func checkOperation(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operation == generation else { throw CancellationError() }
    }

    private func ensureLoaded(modelURL: URL, useGPU: Bool, operation: UUID) async throws {
        let configuration = modelURL.standardizedFileURL.path + (useGPU ? ":gpu" : ":cpu")
        if loadedConfiguration == configuration, process?.isRunning == true, session != nil { return }
        stopProcess()
        session?.invalidateAndCancel()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.timeoutIntervalForResource = 600
        sessionConfig.connectionProxyDictionary = [:]
        session = URLSession(configuration: sessionConfig)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw TranslationError.invalidInput("モデルファイルが見つかりません。モデル管理からダウンロードしてください。") }
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("engine/llama-server").path, "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw TranslationError.engineMissing }
        status = "モデルを読み込み中…"
        port = Int.random(in: 49152...65535)
        apiKey = UUID().uuidString + UUID().uuidString
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: executable)
        worker.arguments = ["-m", modelURL.path, "--host", "127.0.0.1", "--port", String(port), "--api-key", apiKey, "--alias", "plamo-3-translate", "-c", "16384", "-np", "1", "-ngl", useGPU ? "99" : "0", "--no-webui"]
        worker.standardInput = FileHandle.nullDevice
        // Server diagnostics are kept out of a pipe so a full pipe cannot deadlock loading.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("LocalTranslate-engine-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        logHandle = try FileHandle(forWritingTo: logURL)
        worker.standardOutput = logHandle
        worker.standardError = logHandle
        process = worker
        try worker.run()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try checkOperation(operation)
            guard worker.isRunning else {
                stopProcess()
                throw TranslationError.startup("モデルを読み込めませんでした。空きメモリ、モデルファイル、翻訳エンジンの対応状況を確認してください。")
            }
            var request = makeRequest(path: "/health")
            request.httpMethod = "GET"
            request.timeoutInterval = 2
            if let session, let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                try checkOperation(operation)
                loadedConfiguration = configuration
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stopProcess()
        throw TranslationError.startup("モデルの読み込みがタイムアウトしました。小さなモデル、または CPU モードをお試しください。")
    }

    private func makeRequest(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func jsonRequest(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let session else { throw CancellationError() }
        var request = makeRequest(path: path)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslationError.server("翻訳エンジンから正しい応答を受信できませんでした。") }
        return result
    }

    private func stopProcess() {
        if let worker = process, worker.isRunning {
            worker.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        loadedConfiguration = nil
        try? logHandle?.close()
        logHandle = nil
    }
}
