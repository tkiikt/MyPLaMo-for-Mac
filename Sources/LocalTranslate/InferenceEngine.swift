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

struct TranslationPair: Equatable {
    let source: String
    let target: String
}

struct PromptBuilder {
    static let maximumCharacters = 6000
    static let languageCodes: Set<String> = Set("ja en zh-hans zh-hant ko ar az be bg bn ca ceb de es et eu fa fr gu he hi hr hu hy id it jv ka kk km lt lv ml mr ms my ne nl pa pl ru si sk sl sr sw ta te th tl ur uz vi".split(separator: " ").map(String.init))

    static func validateContent(_ text: String) throws {
        guard !text.contains("<|plamo:") else {
            throw TranslationError.invalidInput("文章・文脈・用語にモデルの制御記号が含まれています。記号を取り除いてください。")
        }
    }
    static func prefixUTF16(_ text: String, limit: Int) -> String {
        var result = "", length = 0
        for character in text {
            let value = String(character), count = value.utf16.count
            if length + count > limit { break }
            result += value; length += count
        }
        return result
    }
    static func validateOptions(source: String?, target: String, style: String?) throws {
        guard languageCodes.contains(target), source == nil || languageCodes.contains(source!), source != target else {
            throw TranslationError.invalidInput("対応する異なる翻訳元・翻訳先の言語を選択してください。")
        }
        guard style == nil || ["", "plain", "polite"].contains(style!) else {
            throw TranslationError.invalidInput("文体の指定を確認してください。")
        }
    }
    static func make(text: String, source: String? = nil, target: String, style: String? = nil,
                     context: String = "", glossary: [GlossaryTerm] = [], history: [TranslationPair] = []) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalidInput("翻訳する文章を入力してください。")
        }
        guard text.count <= maximumCharacters else {
            throw TranslationError.invalidInput("一度に翻訳できる原文は \(maximumCharacters) 文字までです。文章を分けてください。")
        }
        try validateOptions(source: source, target: target, style: style)
        try validateContent(text); try validateContent(context)
        for pair in history { try validateContent(pair.source); try validateContent(pair.target) }
        for term in glossary { try validateContent(term.source); try validateContent(term.target) }
        let terms = try GlossaryStore.matchingTerms(glossary, text: text, source: source, target: target)
        func input(_ value: String) -> String {
            "<|plamo:tag|>input" + (source.map { "<|plamo:key|>lang<|plamo:val|>" + $0 } ?? "") + "<|plamo:msg|>" + value
        }
        func output(_ value: String) -> String {
            "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + target + "<|plamo:msg|>" + value
        }
        var prompt = "<|plamo:tag|>dataset<|plamo:msg|>translation"
        if !context.isEmpty { prompt += "<|plamo:tag|>context<|plamo:msg|>" + prefixUTF16(context, limit: 1200) }
        var recent = Array(history.suffix(2))
        while recent.reduce(0, { $0 + $1.source.utf16.count + $1.target.utf16.count }) > 1600 { recent.removeFirst() }
        for pair in recent { prompt += input(pair.source) + output(pair.target) }
        if !terms.isEmpty {
            prompt += "<|plamo:tag|>glossary"
            for term in terms { prompt += "<|plamo:index|>" + term.source + "<|plamo:item|>" + term.target }
        }
        prompt += input(text) + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + target
        if target == "ja", let style, !style.isEmpty { prompt += "<|plamo:key|>form<|plamo:val|>" + style }
        return prompt + "<|plamo:msg|>"
    }
}

@MainActor final class InferenceEngine: ObservableObject {
    @Published private(set) var status = "MLXモデル未読み込み"
    @Published private(set) var isBusy = false
    @Published private(set) var output = ""
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var reader: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var pending: CheckedContinuation<String, Error>?
    private var requestID: String?
    private var generation = UUID()
    private var bytes = Data()
    private var diagnostic: FileHandle?
    private var diagnosticURL: URL?
    private var activeGPU = true

    func translate(text: String, source: String? = nil, target: String, style: String? = nil, modelURL: URL, useGPU: Bool, context: String = "", glossary: [GlossaryTerm] = [], history: [TranslationPair] = []) async throws -> String {
        guard !isBusy else { throw TranslationError.invalidInput("翻訳が終わるまでお待ちください。") }
        try Task.checkCancellation()
        let prompt = try PromptBuilder.make(text: text, source: source, target: target, style: style, context: context, glossary: glossary, history: history)
        guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent(".myplamo-verified.json").path) else {
            throw TranslationError.invalidInput("MLXモデル一式をモデル画面で検証・ダウンロードしてください。GGUFモデルは使用できません。")
        }
        try startWorker()
        let id = UUID().uuidString
        requestID = id; activeGPU = useGPU; isBusy = true; output = ""; status = "MLXモデルを準備中…"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                do {
                    let request: [String: Any] = ["id": id, "prompt": prompt, "model_path": modelURL.path, "max_tokens": 8192, "device": useGPU ? "gpu" : "cpu"]
                    var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
                    try inputPipe?.fileHandleForWriting.write(contentsOf: data)
                    timer = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(480)) } catch { return }
                        guard let self, self.requestID == id else { return }
                        self.finish(.failure(TranslationError.server("翻訳がタイムアウトしました。文章を短くするか、小さいモデルを選んでください。")))
                        self.stopWorker()
                    }
                } catch { finish(.failure(error)); stopWorker() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.requestID == id { self?.cancel() }
            }
        }
    }

    private func startWorker() throws {
        if process?.isRunning == true { return }
        stopWorker()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = Bundle.main.resourceURL
        let candidates: [(URL, URL)] = [
            (resources?.appendingPathComponent("runtime/bin/python3"), resources?.appendingPathComponent("Runtime/mlx_worker.py")),
            (root.appendingPathComponent(".venv/bin/python"), root.appendingPathComponent("Runtime/mlx_worker.py"))
        ].compactMap { python, worker in guard let python, let worker else { return nil }; return (python, worker) }
        guard let (python, script) = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.0.path) && FileManager.default.fileExists(atPath: $0.1.path) }) else { throw TranslationError.engineMissing }
        let worker = Process(), input = Pipe(), output = Pipe()
        let instance = UUID(); generation = instance
        worker.executableURL = python
        worker.arguments = ["-u", script.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"; env["PYTHONNOUSERSITE"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MyPLaMo", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        env["HF_HOME"] = cache.appendingPathComponent("huggingface").path
        env["NUMBA_CACHE_DIR"] = cache.appendingPathComponent("numba").path
        env.removeValue(forKey: "PYTHONHOME"); env.removeValue(forKey: "PYTHONPATH")
        if let resources, python.path.hasPrefix(resources.path + "/runtime/") { env["PYTHONHOME"] = resources.appendingPathComponent("runtime").path }
        worker.environment = env
        worker.currentDirectoryURL = script.deletingLastPathComponent()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("MyPLaMo-MLX-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        diagnostic = try FileHandle(forWritingTo: log); diagnosticURL = log
        worker.standardInput = input; worker.standardOutput = output; worker.standardError = diagnostic
        let stream = AsyncStream<Data> { continuation in
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { continuation.finish() } else { continuation.yield(data) }
            }
        }
        process = worker; inputPipe = input; outputPipe = output
        worker.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.generation == instance else { return }
                // Pipe EOF may be delivered after termination; the reader drains all
                // complete messages before reporting an unexpected worker exit.
                if process.terminationStatus != 0 {
                    self.finish(.failure(TranslationError.startup("MLX処理が終了しました。メモリの空きとモデルを確認してください。")))
                    self.stopWorker()
                }
            }
        }
        try worker.run()
        reader = Task { [weak self] in
            for await chunk in stream {
                guard let self, self.generation == instance else { return }
                self.bytes.append(chunk)
                while let end = self.bytes.firstIndex(of: 10) {
                    let line = Data(self.bytes[..<end]); self.bytes.removeSubrange(...end)
                    self.consume(line)
                }
                if self.bytes.count > 1_000_000 { self.finish(.failure(TranslationError.server("MLXから不正な応答を受信しました。"))); self.stopWorker(); return }
            }
            guard let self, self.generation == instance else { return }
            if self.pending != nil { self.finish(.failure(TranslationError.server("MLXとの接続が終了しました。再度翻訳してください。"))) }
            self.stopWorker()
        }
    }
    private func consume(_ line: Data) {
        guard let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = item["id"] as? String, id == requestID else { return }
        switch item["type"] as? String {
        case "token":
            output += item["text"] as? String ?? ""; status = "MLXで翻訳中…"
        case "done":
            if item["finish_reason"] as? String == "length" { finish(.failure(TranslationError.truncated)); return }
            guard item["finish_reason"] as? String == "stop" else { finish(.failure(TranslationError.server("訳文が完了しませんでした。"))); return }
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(output.isEmpty ? .failure(TranslationError.emptyResult) : .success(output))
        case "error": finish(.failure(TranslationError.server("MLX翻訳エラー: \(item["message"] as? String ?? "不明なエラー")")))
        default: break
        }
    }
    private func finish(_ result: Result<String, Error>) {
        timer?.cancel(); timer = nil
        let continuation = pending; pending = nil; requestID = nil; isBusy = false
        switch result {
        case .success: status = activeGPU ? "準備完了 · MLX / Apple GPU" : "準備完了 · MLX / CPU"
        case .failure(let error): status = error is CancellationError ? "翻訳を中止しました" : "翻訳できませんでした"
        }
        continuation?.resume(with: result)
    }
    func cancel() { finish(.failure(CancellationError())); stopWorker() }
    func shutdown() { cancel(); status = "MLXモデル未読み込み" }
    private func stopWorker() {
        generation = UUID(); reader?.cancel(); reader = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        if let worker = process, worker.isRunning {
            worker.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if worker.isRunning { kill(worker.processIdentifier, SIGKILL) } }
        }
        process = nil; inputPipe = nil; outputPipe = nil; bytes = Data()
        try? diagnostic?.close(); diagnostic = nil
        if let url = diagnosticURL { try? FileManager.default.removeItem(at: url) }; diagnosticURL = nil
    }
}
