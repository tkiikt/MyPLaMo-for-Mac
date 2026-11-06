import AppKit
import Combine
import CryptoKit
import Foundation

struct MLXModelFile: Codable, Equatable {
    let path: String
    let size: Int64
    let digest: String
    let isLFS: Bool
}

struct TranslationModel: Identifiable, Codable, Equatable {
    let id: String
    var title: String { "PLaMo 3 Translate \(id.uppercased()) · MLX" }
    var filename: String
    var size: Int64
    var sha256: String?
    var installed = false
    var revision: String = ""
    var files: [MLXModelFile] = []
    var repository: String { "pfnet/plamo-3-translate-\(id)-MLX-4bit" }
}

private enum ModelFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private struct MLXResume: Codable {
    let model: TranslationModel
    let folder: URL
    var currentPath: String?
    var resumeData: Data?
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: (Int64) -> Void
    let completion: (Result<URL, Error>) -> Void
    private var delivered = false
    init(destination: URL, progress: @escaping (Int64) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination; self.progress = progress; self.completion = completion
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        delivered = true
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else { throw ModelFailure.message("モデル配布元から正常な応答を取得できませんでした。") }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            completion(.success(destination))
        } catch { completion(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if !delivered, let error { delivered = true; completion(.failure(error)) }
    }
}

@MainActor final class ModelManager: ObservableObject {
    @Published var models: [TranslationModel]
    @Published private(set) var folder: URL
    @Published var selectedID: String { didSet { defaults.set(selectedID, forKey: "selectedModelID") } }
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var bytesPerSecond = 0.0
    @Published private(set) var remainingBytes: Int64 = 0
    @Published private(set) var status = "MLXモデルを選択してください"
    @Published var error: String?
    @Published private(set) var pausedModelID: String?
    private let defaults: UserDefaults
    private let support: URL
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var operation: Task<Void, Never>?
    private var activeResume: MLXResume?
    private var paused = false
    private var metadataBusy = false
    private var generation = UUID()
    private var started = Date()
    private var initialBytes: Int64?
    private var pauseCompletions: [() -> Void] = []
    private var resumeURL: URL { support.appendingPathComponent("mlx-download.json") }
    private var metadataURL: URL { support.appendingPathComponent("mlx-model-metadata.json") }
    nonisolated private static let marker = ".myplamo-verified.json"

    var selectedModelURL: URL? {
        guard let model = models.first(where: { $0.id == selectedID && $0.installed }) else { return nil }
        return folder.appendingPathComponent(model.filename, isDirectory: true)
    }
    init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyPLaMo", isDirectory: true)
        support = home
        folder = defaults.string(forKey: "mlxModelFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent("ModelsMLX", isDirectory: true)
        selectedID = defaults.string(forKey: "selectedModelID") ?? "2b"
        models = ["0.8b", "2b", "8b", "31b"].map { TranslationModel(id: $0, filename: "plamo-3-translate-\($0)-MLX-4bit", size: 0, sha256: nil) }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: home.appendingPathComponent("mlx-model-metadata.json")), let cached = try? JSONDecoder().decode([TranslationModel].self, from: data) {
            for model in cached where Self.validManifest(model) { if let i = models.firstIndex(where: { $0.id == model.id }) { models[i] = model } }
        }
        if let data = try? Data(contentsOf: home.appendingPathComponent("mlx-download.json")), let saved = try? JSONDecoder().decode(MLXResume.self, from: data), Self.validManifest(saved.model) { pausedModelID = saved.model.id }
        scanInstalled()
    }

    func scanInstalled() {
        for i in models.indices {
            let directory = folder.appendingPathComponent(models[i].filename)
            let marker = directory.appendingPathComponent(Self.marker)
            guard let data = try? Data(contentsOf: marker), let manifest = try? JSONDecoder().decode(TranslationModel.self, from: data), Self.validManifest(manifest), manifest.id == models[i].id else { models[i].installed = false; continue }
            models[i].installed = manifest.files.allSatisfy { file in
                let values = try? directory.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                return values?.isRegularFile == true && values?.isSymbolicLink != true && Int64(values?.fileSize ?? -1) == file.size
            }
        }
    }

    func refreshMetadata() async {
        guard !metadataBusy else { return }
        metadataBusy = true; defer { metadataBusy = false }
        do {
            for id in models.map(\.id) {
                var model = try await Self.fetchManifest(id)
                if let i = models.firstIndex(where: { $0.id == id }) {
                    model.installed = models[i].installed
                    models[i] = model
                }
            }
            try JSONEncoder().encode(models).write(to: metadataURL, options: .atomic)
            scanInstalled()
            await verifyExistingModels()
        } catch { self.error = "MLXモデル情報を取得できません: \(error.localizedDescription)"; scanInstalled() }
    }

    nonisolated private static func fetchManifest(_ id: String) async throws -> TranslationModel {
        struct Repository: Decodable {
            struct File: Decodable {
                struct LFS: Decodable { let sha256: String }
                let rfilename: String; let blobId: String; let size: Int64; let lfs: LFS?
            }
            let sha: String; let siblings: [File]
        }
        let repository = "pfnet/plamo-3-translate-\(id)-MLX-4bit"
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ModelFailure.message("公式配布元への接続を確認してください。") }
        let info = try JSONDecoder().decode(Repository.self, from: data)
        let files = info.siblings.filter { !$0.rfilename.hasPrefix("figures/") && $0.rfilename != ".gitattributes" }.map { entry in
            MLXModelFile(path: entry.rfilename, size: entry.size, digest: entry.lfs?.sha256 ?? entry.blobId, isLFS: entry.lfs != nil)
        }.sorted { $0.path < $1.path }
        let model = TranslationModel(id: id, filename: "plamo-3-translate-\(id)-MLX-4bit", size: files.reduce(0) { $0 + $1.size }, sha256: nil, revision: info.sha, files: files)
        guard validManifest(model) else { throw ModelFailure.message("公式モデルの構成・検証情報を確認できませんでした。") }
        return model
    }

    nonisolated private static func validManifest(_ model: TranslationModel) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        func digest(_ value: String, count: Int) -> Bool { value.count == count && value.unicodeScalars.allSatisfy(hex.contains) }
        guard ["0.8b", "2b", "8b", "31b"].contains(model.id), model.filename == "plamo-3-translate-\(model.id)-MLX-4bit", digest(model.revision, count: 40), !model.files.isEmpty else { return false }
        let paths = Set(model.files.map(\.path))
        guard paths.count == model.files.count, paths.contains("config.json"), paths.contains("tokenizer_config.json"), paths.contains("modeling_plamo_mlx.py"), paths.contains("tokenization_plamo.py"), model.files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { return false }
        return model.files.allSatisfy { file in
            !file.path.hasPrefix("/") && !file.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty || $0 == "." }) && !file.path.contains("\\") && file.size >= 0 && digest(file.digest, count: file.isLFS ? 64 : 40)
        }
    }

    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "MLXモデル保存先にする"; panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }
    func setFolder(_ url: URL) {
        guard !isBusy else { return }
        folder = url; defaults.set(url.path, forKey: "mlxModelFolder"); scanInstalled()
        Task { await verifyExistingModels() }
    }
    func verifyExistingModels() async {
        guard !isBusy else { return }
        let root = folder
        let candidates = models.filter { !$0.installed && Self.validManifest($0) && FileManager.default.fileExists(atPath: root.appendingPathComponent($0.filename).path) }
        guard !candidates.isEmpty else { return }
        isBusy = true; status = "既存のMLXモデルを検証中"
        defer { isBusy = false; scanInstalled() }
        for model in candidates {
            do {
                let directory = root.appendingPathComponent(model.filename)
                try await Task.detached(priority: .utility) { try Self.verifyDirectory(directory, model: model) }.value
                try JSONEncoder().encode(model).write(to: directory.appendingPathComponent(Self.marker), options: .atomic)
                status = "既存のMLXモデルを確認しました"
            } catch { self.error = "既存モデルの検証に失敗しました: \(error.localizedDescription)" }
        }
    }

    private func checkDestination(_ model: TranslationModel, root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appendingPathComponent(".write-test-\(UUID().uuidString)")
        try Data().write(to: probe); try fm.removeItem(at: probe)
        let free = ((try fm.attributesOfFileSystem(forPath: root.path))[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let staging = root.appendingPathComponent(".\(model.filename).partial")
        let existing = model.files.reduce(Int64(0)) { result, file in
            result + Int64((try? staging.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard free > max(0, model.size - existing) + 256_000_000 else { throw ModelFailure.message("保存先の空き容量が不足しています。") }
    }
    func download(_ model: TranslationModel) async {
        guard !isBusy else { return }
        error = nil; isBusy = true; status = "MLXモデル情報を確認中"
        do {
            let current = Self.validManifest(model) ? model : try await Self.fetchManifest(model.id)
            if let i = models.firstIndex(where: { $0.id == model.id }) { models[i] = current }
            try JSONEncoder().encode(models).write(to: metadataURL, options: .atomic)
            scanInstalled()
            if models.first(where: { $0.id == model.id })?.installed == true { isBusy = false; status = "このMLXモデルは保存済みです"; return }
            let saved = (try? Data(contentsOf: resumeURL)).flatMap { try? JSONDecoder().decode(MLXResume.self, from: $0) }
            let record = saved.flatMap { $0.model.id == current.id && $0.folder == folder ? $0 : nil } ?? MLXResume(model: current, folder: folder)
            try checkDestination(record.model, root: record.folder)
            begin(record)
        } catch { self.error = error.localizedDescription; isBusy = false }
    }
    func resume() async {
        guard !isBusy else { return }
        do {
            let saved = try JSONDecoder().decode(MLXResume.self, from: Data(contentsOf: resumeURL))
            guard Self.validManifest(saved.model) else { throw ModelFailure.message("再開情報が正しくありません。モデルを選び直してください。") }
            folder = saved.folder; defaults.set(folder.path, forKey: "mlxModelFolder")
            try checkDestination(saved.model, root: saved.folder)
            error = nil; begin(saved)
        } catch { self.error = error.localizedDescription }
    }
    private func begin(_ record: MLXResume) {
        isBusy = true; paused = false; activeResume = record; pausedModelID = record.model.id
        started = Date(); initialBytes = nil; progress = 0; bytesPerSecond = 0; remainingBytes = record.model.size
        generation = UUID(); let token = generation
        operation = Task { await runDownload(record, token: token) }
    }
    private func saveResume() throws {
        if let activeResume { try JSONEncoder().encode(activeResume).write(to: resumeURL, options: .atomic); pausedModelID = activeResume.model.id }
    }
    private func runDownload(_ record: MLXResume, token: UUID) async {
        let model = record.model
        let staging = record.folder.appendingPathComponent(".\(model.filename).partial", isDirectory: true)
        let destination = record.folder.appendingPathComponent(model.filename, isDirectory: true)
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw ModelFailure.message("同名のモデルフォルダがあります。既存モデルを検証するか、別の保存先を選んでください。") }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try saveResume()
            var completed: Int64 = 0
            for file in model.files {
                if paused { throw CancellationError() }
                let fileURL = staging.appendingPathComponent(file.path)
                let valid = await Task.detached(priority: .utility) { (try? Self.verifyFile(fileURL, file: file)) != nil }.value
                if !valid {
                    status = "\(model.title) · \(file.path) を取得中"
                    activeResume?.currentPath = file.path
                    if record.currentPath != file.path { activeResume?.resumeData = nil }
                    try saveResume()
                    let partial = fileURL.appendingPathExtension("download")
                    let amount = completed
                    let resume = activeResume?.resumeData
                    let fetched = try await fetch(file: file, model: model, destination: partial, resumeData: resume) { [weak self] bytes in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            let current = amount + bytes
                            if self.initialBytes == nil { self.initialBytes = current }
                            self.progress = min(1, Double(current) / Double(model.size))
                            self.remainingBytes = max(0, model.size - current)
                            self.bytesPerSecond = Double(max(0, current - (self.initialBytes ?? 0))) / max(0.1, Date().timeIntervalSince(self.started))
                        }
                    }
                    status = "\(file.path) を検証中"
                    try await Task.detached(priority: .utility) { try Self.verifyFile(fetched, file: file) }.value
                    if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
                    try FileManager.default.moveItem(at: fetched, to: fileURL)
                    activeResume?.resumeData = nil; activeResume?.currentPath = nil; try saveResume()
                }
                completed += file.size
                progress = Double(completed) / Double(model.size); remainingBytes = model.size - completed
            }
            if paused { throw CancellationError() }
            // Marker is written only after each file has passed its pinned official digest.
            try JSONEncoder().encode(model).write(to: staging.appendingPathComponent(Self.marker), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.removeItem(at: resumeURL)
            activeResume = nil; pausedModelID = nil; selectedID = model.id
            progress = 1; remainingBytes = 0; status = "MLXモデルの準備ができました"
        } catch {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { activeResume?.resumeData = data }
            try? saveResume()
            if paused || error is CancellationError || (error as? URLError)?.code == .cancelled { status = "ダウンロードを一時停止しました" }
            else { self.error = error.localizedDescription; status = "取得を中断しました。再開または再試行できます" }
        }
        session?.invalidateAndCancel(); session = nil; downloadTask = nil; operation = nil
        isBusy = false; scanInstalled()
        let completions = pauseCompletions; pauseCompletions = []; completions.forEach { $0() }
    }

    private func fetch(file: MLXModelFile, model: TranslationModel, destination: URL, resumeData: Data?, progress: @escaping (Int64) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = ModelDownloadDelegate(destination: destination, progress: progress) { continuation.resume(with: $0) }
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 86400
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            self.session = session
            let task: URLSessionDownloadTask
            if let resumeData { task = session.downloadTask(withResumeData: resumeData) }
            else {
                let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file.path)")!
                task = session.downloadTask(with: url)
            }
            self.downloadTask = task
            task.resume()
        }
    }
    func pause(onPaused: (() -> Void)? = nil) {
        guard operation != nil else { onPaused?(); return }
        if let onPaused { pauseCompletions.append(onPaused) }
        paused = true
        // didCompleteWithError contains resume data; one completion path persists it
        // before the application is allowed to terminate.
        downloadTask?.cancel(byProducingResumeData: { _ in })
    }

    func delete(_ model: TranslationModel) throws {
        guard !isBusy else { throw ModelFailure.message("モデルの処理が終わるまでお待ちください。") }
        guard model.filename == "plamo-3-translate-\(model.id)-MLX-4bit" else { return }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(model.filename)); scanInstalled()
    }
    func moveModels(to newFolder: URL) async {
        guard !isBusy, newFolder.standardizedFileURL != folder.standardizedFileURL else { return }
        isBusy = true; status = "MLXモデルを移動中"
        let oldFolder = folder, installed = models.filter(\.installed)
        do {
            try await Task.detached(priority: .utility) {
                let fm = FileManager.default; try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
                var copied: [URL] = []
                do {
                    for model in installed {
                        let source = oldFolder.appendingPathComponent(model.filename), destination = newFolder.appendingPathComponent(model.filename)
                        guard !fm.fileExists(atPath: destination.path) else { throw ModelFailure.message("移動先に同名のモデルがあります。") }
                        let manifest = try JSONDecoder().decode(TranslationModel.self, from: Data(contentsOf: source.appendingPathComponent(Self.marker)))
                        guard Self.validManifest(manifest) else { throw ModelFailure.message("モデルの検証情報が正しくありません。") }
                        try fm.copyItem(at: source, to: destination); copied.append(destination)
                        try Self.verifyDirectory(destination, model: manifest)
                    }
                } catch { for url in copied { try? fm.removeItem(at: url) }; throw error }
            }.value
            isBusy = false; setFolder(newFolder); status = "MLXモデルを移動しました"
            do { for model in installed { try FileManager.default.removeItem(at: oldFolder.appendingPathComponent(model.filename)) } }
            catch { self.error = "移動先は使用できますが元のコピーを削除できませんでした: \(error.localizedDescription)" }
        } catch { self.error = error.localizedDescription; isBusy = false; scanInstalled() }
    }

    nonisolated private static func verifyDirectory(_ url: URL, model: TranslationModel) throws {
        guard validManifest(model) else { throw ModelFailure.message("MLXモデルの構成が正しくありません。") }
        for file in model.files { try verifyFile(url.appendingPathComponent(file.path), file: file) }
    }
    nonisolated private static func verifyFile(_ url: URL, file: MLXModelFile) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == file.size else { throw ModelFailure.message("\(file.path) のサイズまたは形式が正しくありません。") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var sha = SHA256(), git = Insecure.SHA1()
        if !file.isLFS { git.update(data: Data("blob \(file.size)\0".utf8)) }
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            if file.isLFS { sha.update(data: data) } else { git.update(data: data) }
        }
        let digest = file.isLFS ? sha.finalize().map { String(format: "%02x", $0) }.joined() : git.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.digest else { throw ModelFailure.message("\(file.path) のハッシュ検証に失敗しました。再取得してください。") }
    }
}
