import AppKit
import Combine
import CryptoKit
import Foundation

struct TranslationModel: Identifiable, Codable, Equatable {
    let id: String
    var title: String { "PLaMo 3 Translate \(id.uppercased())" }
    var filename: String
    var size: Int64
    var sha256: String?
    var installed = false
    var repository: String { "pfnet/plamo-3-translate-\(id)-GGUF" }
}

private enum ModelFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let stagingURL: URL
    let progress: (Int64, Int64) -> Void
    let completion: (Result<URL, Error>) -> Void
    var delivered = false
    init(stagingURL: URL, progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.stagingURL = stagingURL; self.progress = progress; self.completion = completion
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        delivered = true
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 || response.statusCode == 206 else {
                throw ModelFailure.message("ダウンロード元がエラーを返しました。再試行してください。")
            }
            try FileManager.default.moveItem(at: location, to: stagingURL)
            completion(.success(stagingURL))
        } catch { completion(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !delivered, let error { completion(.failure(error)) }
    }
}

@MainActor final class ModelManager: ObservableObject {
    @Published var models: [TranslationModel]
    @Published private(set) var folder: URL
    @Published var selectedID: String { didSet { UserDefaults.standard.set(selectedID, forKey: "selectedModelID") } }
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var bytesPerSecond = 0.0
    @Published private(set) var remainingBytes: Int64 = 0
    @Published private(set) var status = "モデルを選択してください"
    @Published var error: String?
    @Published private(set) var pausedModelID: String?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var generation = UUID()
    private var started = Date()
    private var initialBytes: Int64?
    private let support: URL
    private var resumeURL: URL { support.appendingPathComponent("download.resume") }
    private var resumeIDURL: URL { support.appendingPathComponent("download-model.txt") }
    private var metadataURL: URL { support.appendingPathComponent("model-metadata.json") }
    var selectedModelURL: URL? {
        guard let model = models.first(where: { $0.id == selectedID && $0.installed }) else { return nil }
        return folder.appendingPathComponent(model.filename)
    }
    init() {
        let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalTranslate", isDirectory: true)
        support = home
        folder = UserDefaults.standard.string(forKey: "modelFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent("Models", isDirectory: true)
        selectedID = UserDefaults.standard.string(forKey: "selectedModelID") ?? "2b"
        models = ["0.8b", "2b", "8b", "31b"].map { TranslationModel(id: $0, filename: "plamo-3-translate-\($0)-Q4_K_M.gguf", size: 0, sha256: nil) }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: home.appendingPathComponent("model-metadata.json")), let cached = try? JSONDecoder().decode([TranslationModel].self, from: data) {
            for model in cached { if let i = models.firstIndex(where: { $0.id == model.id }) { models[i] = model } }
        }
        pausedModelID = try? String(contentsOf: home.appendingPathComponent("download-model.txt"), encoding: .utf8)
        scanInstalled()
    }
    func scanInstalled() {
        for i in models.indices {
            let url = folder.appendingPathComponent(models[i].filename)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            models[i].installed = size > 0 && (models[i].size == 0 || size == models[i].size)
        }
    }
    func refreshMetadata() async {
        do {
            struct Entry: Decodable {
                struct LFS: Decodable { let oid: String }
                let path: String; let size: Int64; let lfs: LFS?
            }
            for model in models {
                let url = URL(string: "https://huggingface.co/api/models/\(model.repository)/tree/main")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ModelFailure.message("モデル情報を取得できません。接続を確認してください。") }
                let entries = try JSONDecoder().decode([Entry].self, from: data)
                guard let entry = entries.first(where: { $0.path == model.filename }), let sha = entry.lfs?.oid, sha.count == 64, entry.size > 0 else { throw ModelFailure.message("公式モデル情報に必要な検証情報がありません。") }
                if let i = models.firstIndex(where: { $0.id == model.id }) { models[i].size = entry.size; models[i].sha256 = sha }
            }
            try JSONEncoder().encode(models).write(to: metadataURL, options: .atomic)
            scanInstalled()
        } catch { self.error = error.localizedDescription }
    }
    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "モデル保存先にする"; panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }
    func setFolder(_ url: URL) {
        guard !isBusy else { return }
        folder = url; UserDefaults.standard.set(url.path, forKey: "modelFolder"); scanInstalled()
    }
    private func checkDestination(_ model: TranslationModel) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let probe = folder.appendingPathComponent(".write-test-\(UUID().uuidString)")
        try Data().write(to: probe); try fm.removeItem(at: probe)
        let attrs = try fm.attributesOfFileSystem(forPath: folder.path)
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > model.size + 256_000_000 else { throw ModelFailure.message("保存先の空き容量が不足しています。別のフォルダを選んでください。") }
    }
    func download(_ model: TranslationModel) async {
        guard !isBusy else { return }
        error = nil; isBusy = true; status = "モデル情報を確認中"
        if model.sha256 == nil { await refreshMetadata() }
        guard let current = models.first(where: { $0.id == model.id }), current.sha256 != nil else { isBusy = false; return }
        do {
            try checkDestination(current)
            if current.installed { status = "このモデルは保存済みです"; isBusy = false; return }
            clearResume()
            begin(current, resumeData: nil)
        } catch { self.error = error.localizedDescription; isBusy = false }
    }
    func resume() async {
        guard !isBusy, let id = pausedModelID, let model = models.first(where: { $0.id == id }) else { return }
        do {
            try checkDestination(model)
            guard model.sha256 != nil else { throw ModelFailure.message("モデル情報を再取得してから再開してください。") }
            let data = try Data(contentsOf: resumeURL)
            begin(model, resumeData: data)
        } catch { self.error = error.localizedDescription }
    }
    private func begin(_ model: TranslationModel, resumeData: Data?) {
        let token = UUID(); generation = token; isBusy = true; progress = 0; bytesPerSecond = 0; remainingBytes = model.size
        status = "\(model.title) をダウンロード中"; started = Date(); initialBytes = nil
        let destination = folder.appendingPathComponent(model.filename)
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).download")
        let delegate = ModelDownloadDelegate(stagingURL: staging, progress: { [weak self] bytes, total in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if self.initialBytes == nil { self.initialBytes = bytes }
                self.progress = Double(bytes) / Double(max(total, model.size))
                self.bytesPerSecond = Double(bytes - (self.initialBytes ?? 0)) / max(Date().timeIntervalSince(self.started), 0.1)
                self.remainingBytes = max(0, model.size - bytes)
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == token else {
                    if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }; return
                }
                self.task = nil
                self.session?.finishTasksAndInvalidate(); self.session = nil
                switch result {
                case .success(let url):
                    self.status = "ダウンロードを検証中"
                    do {
                        try await Task.detached(priority: .utility) { try Self.verify(url, model: model) }.value
                        guard self.generation == token else { try? FileManager.default.removeItem(at: url); return }
                        if FileManager.default.fileExists(atPath: destination.path) { throw ModelFailure.message("同名のモデルが既にあります。既存ファイルを確認してください。") }
                        try FileManager.default.moveItem(at: url, to: destination)
                        self.clearResume(); self.progress = 1; self.remainingBytes = 0; self.status = "モデルの準備ができました"; self.scanInstalled()
                    } catch { try? FileManager.default.removeItem(at: url); self.error = error.localizedDescription; self.status = "モデルを準備できませんでした" }
                case .failure(let error):
                    if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { self.saveResume(resume, id: model.id) }
                    self.error = error.localizedDescription; self.status = "ダウンロードに失敗しました。再開または再試行できます"
                }
                self.isBusy = false
            }
        })
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        let download: URLSessionDownloadTask
        if let resumeData { download = session.downloadTask(withResumeData: resumeData) }
        else { download = session.downloadTask(with: URL(string: "https://huggingface.co/\(model.repository)/resolve/main/\(model.filename)")!) }
        task = download
        try? model.id.write(to: resumeIDURL, atomically: true, encoding: .utf8)
        download.resume()
    }
    func pause(onPaused: (() -> Void)? = nil) {
        guard let task else { onPaused?(); return }
        let id = (try? String(contentsOf: resumeIDURL, encoding: .utf8)) ?? selectedID
        generation = UUID(); self.task = nil
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.saveResume(data, id: id); self.status = "ダウンロードを一時停止しました" }
                else { self.status = "停止しました。再試行で最初からダウンロードできます"; self.clearResume() }
                self.isBusy = false; self.session?.invalidateAndCancel(); self.session = nil
                onPaused?()
            }
        }
    }
    private func saveResume(_ data: Data, id: String) {
        do { try data.write(to: resumeURL, options: .atomic); try id.write(to: resumeIDURL, atomically: true, encoding: .utf8); pausedModelID = id }
        catch { self.error = "再開情報を保存できませんでした: \(error.localizedDescription)" }
    }
    private func clearResume() { try? FileManager.default.removeItem(at: resumeURL); try? FileManager.default.removeItem(at: resumeIDURL); pausedModelID = nil }
    func delete(_ model: TranslationModel) throws {
        guard !isBusy else { throw ModelFailure.message("ダウンロード完了後に削除してください。") }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(model.filename)); scanInstalled()
    }
    func moveModels(to newFolder: URL) async {
        guard !isBusy, newFolder.standardizedFileURL != folder.standardizedFileURL else { return }
        isBusy = true; status = "モデルを移動中"
        let oldFolder = folder, installed = models.filter(\.installed)
        do {
            try await Task.detached(priority: .utility) {
                let fm = FileManager.default
                try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
                var copied: [URL] = []
                do {
                    for model in installed {
                        let destination = newFolder.appendingPathComponent(model.filename)
                        guard !fm.fileExists(atPath: destination.path) else { throw ModelFailure.message("移動先に同名のモデルがあります。空のフォルダを選んでください。") }
                        try fm.copyItem(at: oldFolder.appendingPathComponent(model.filename), to: destination); copied.append(destination)
                        try Self.verify(destination, model: model)
                    }
                } catch { for url in copied { try? fm.removeItem(at: url) }; throw error }

            }.value
            isBusy = false; setFolder(newFolder); status = "モデルを移動しました"
            // Point at the complete, verified destination before cleaning originals.
            // A cleanup failure must never leave the app using a partial source folder.
            do { for model in installed { try FileManager.default.removeItem(at: oldFolder.appendingPathComponent(model.filename)) } }
            catch { self.error = "移動先のモデルは使用できますが、元のコピーの一部を削除できませんでした: \(error.localizedDescription)" }
        } catch { self.error = error.localizedDescription; isBusy = false; status = "モデルを移動できませんでした"; scanInstalled() }
    }
    nonisolated private static func verify(_ url: URL, model: TranslationModel) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hash.update(data: data); count += Int64(data.count) }
        guard model.size > 0, count == model.size, let expected = model.sha256,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected.lowercased() else {
            throw ModelFailure.message("モデルの検証に失敗しました。再ダウンロードしてください。")
        }
    }
}
