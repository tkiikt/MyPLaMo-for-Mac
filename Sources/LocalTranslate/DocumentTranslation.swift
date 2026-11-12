import Foundation

enum DocumentFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto", text, markdown, json, yaml
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自動判定"
        case .text: return "テキスト"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .yaml: return "YAML"
        }
    }
}

struct DocumentSpan: Codable, Sendable {
    /// Offsets into the original source measured in UTF-16 code units.
    let start: Int
    let end: Int
    let text: String
    let encoding: Encoding
    struct Encoding: Codable, Sendable {
        let kind: String
        let style: String?
        let body: String?
        let header: String?
        let indent: String?
        let newline: String?
        let trailing: Bool?
    }
}

struct DocumentPlan: Codable, Sendable {
    let source: String
    let format: DocumentFormat
    let spans: [DocumentSpan]
}

private struct DocumentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A small offline parser process keeps parser work and pipe I/O off the UI
/// thread. It shares the app's packaged Python environment, not the MLX worker.
enum DocumentTranslation {
    private struct Request: Encodable, Sendable {
        let action: String
        var source: String? = nil
        var format: DocumentFormat? = nil
        var plan: DocumentPlan? = nil
        var translations: [String]? = nil
    }
    private struct Response: Decodable {
        let plan: DocumentPlan?
        let text: String?
        let error: String?
    }
    static func plan(text: String, format: DocumentFormat) async throws -> DocumentPlan {
        let response = try await invoke(Request(action: "plan", source: text, format: format))
        guard let plan = response.plan else { throw DocumentFailure(message: "文書の解析結果が不正です。") }
        return plan
    }
    static func render(plan: DocumentPlan, translations: [String]) async throws -> String {
        let response = try await invoke(Request(action: "render", plan: plan, translations: translations))
        guard let text = response.text else { throw DocumentFailure(message: "文書の組み立て結果が不正です。") }
        return text
    }
    private static func invoke(_ request: Request) async throws -> Response {
        let data = try JSONEncoder().encode(request)
        let job = DocumentParserJob()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let bytes = try await Task.detached(priority: .userInitiated) { try job.run(data) }.value
                try Task.checkCancellation()
                let response = try JSONDecoder().decode(Response.self, from: bytes)
                if let error = response.error { throw DocumentFailure(message: error) }
                return response
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { job.cancel() }
    }
}

private final class DocumentParserJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }
    func run(_ data: Data) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = Bundle.main.resourceURL
        let candidates: [(URL, URL)] = [
            (resources?.appendingPathComponent("runtime/bin/python3"), resources?.appendingPathComponent("Runtime/document_plan.py")),
            (root.appendingPathComponent(".venv/bin/python"), root.appendingPathComponent("Runtime/document_plan.py"))
        ].compactMap { python, script in guard let python, let script else { return nil }; return (python, script) }
        guard let (python, script) = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.0.path) && FileManager.default.fileExists(atPath: $0.1.path) }) else {
            throw DocumentFailure(message: "文書処理の実行環境が見つかりません。アプリを再インストールしてください。")
        }
        let worker = Process(), input = Pipe(), output = Pipe()
        worker.executableURL = python
        worker.arguments = ["-u", script.path]
        worker.standardInput = input; worker.standardOutput = output; worker.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"; environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        if let resources, python.path.hasPrefix(resources.path + "/runtime/") {
            environment["PYTHONHOME"] = resources.appendingPathComponent("runtime").path
        }
        worker.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try worker.run(); process = worker; lock.unlock() }
        catch { lock.unlock(); throw error }
        let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        do { try input.fileHandleForWriting.write(contentsOf: data); try input.fileHandleForWriting.close() }
        catch { cancel(); worker.waitUntilExit(); throw error }
        let response = try output.fileHandleForReading.readToEnd() ?? Data()
        worker.waitUntilExit()
        guard worker.terminationStatus == 0 else { throw DocumentFailure(message: "文書処理を完了できませんでした。文章を短くするか、形式を確認してください。") }
        return response
    }
}
