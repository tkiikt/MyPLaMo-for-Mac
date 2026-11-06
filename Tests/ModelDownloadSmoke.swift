import Foundation

@main struct ModelDownloadSmoke {
    @MainActor static func main() async {
        let manager = ModelManager()
        manager.setFolder(URL(fileURLWithPath: "/Users/hoge/Documents/Codex/LocalTranslate/Models", isDirectory: true))
        await manager.refreshMetadata()
        guard let model = manager.models.first(where: { $0.id == "0.8b" }), model.sha256 != nil else {
            print("FAIL metadata: \(manager.error ?? "missing")"); exit(1)
        }
        print("Metadata: \(model.filename) \(model.size) \(model.sha256!)")
        if model.installed { print("Already installed; no download required"); return }
        await manager.download(model)
        var paused = false
        var lastReport = Date.distantPast
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !paused && manager.progress > 0.015 && manager.progress < 0.8 {
                print("Pausing at \(manager.progress)")
                manager.pause()
                while manager.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
                guard manager.pausedModelID == "0.8b" else { print("FAIL resume data: \(manager.error ?? manager.status)"); exit(2) }
                print("Resume information saved; resuming")
                await manager.resume(); paused = true
            }
            if Date().timeIntervalSince(lastReport) > 5 {
                print("\(manager.status) progress=\(manager.progress) rate=\(manager.bytesPerSecond) remaining=\(manager.remainingBytes)")
                fflush(stdout); lastReport = Date()
            }
            if !manager.isBusy {
                if let error = manager.error { print("FAIL \(error)"); exit(3) }
                guard manager.models.first(where: { $0.id == "0.8b" })?.installed == true else { print("FAIL not installed"); exit(4) }
                print("PASS downloaded, SHA256 verified, installed. pause/resume exercised=\(paused)")
                return
            }
        }
        manager.pause(); print("FAIL timeout"); exit(5)
    }
}
