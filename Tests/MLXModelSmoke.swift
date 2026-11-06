import Foundation
@main struct MLXModelSmoke {
    @MainActor static func main() async {
        let support = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = URL(fileURLWithPath: CommandLine.arguments[2])
        let defaults = UserDefaults(suiteName: "jp.myplamo.model-smoke")!
        let manager = ModelManager(storageURL: support, defaults: defaults)
        manager.setFolder(folder)
        await manager.refreshMetadata()
        if let error = manager.error { print("FAIL metadata \(error)"); exit(1) }
        print("Metadata: \(manager.models.map { "\($0.id):\($0.size)" })")
        guard let model = manager.models.first(where: { $0.id == "0.8b" }) else { exit(1) }
        if model.installed { print("PASS existing MLX model"); return }
        await manager.download(model)
        var paused = false, resumed = false
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if manager.isBusy && manager.progress > 0.05 && !paused { manager.pause(); paused = true }
            if !manager.isBusy, paused, !resumed, manager.pausedModelID != nil { print("PASS pause at \(manager.progress)"); await manager.resume(); resumed = true }
            if !manager.isBusy, let error = manager.error { print("FAIL \(error)"); exit(1) }
            if !manager.isBusy, manager.models.first(where: { $0.id == "0.8b" })?.installed == true { print("PASS verified MLX download \(manager.selectedModelURL!.path)"); return }
            try? await Task.sleep(for: .seconds(1))
        }
        manager.pause(); print("FAIL timeout"); exit(1)
    }
}
