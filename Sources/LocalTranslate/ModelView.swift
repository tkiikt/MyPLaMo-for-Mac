import SwiftUI
import AppKit

struct ModelView: View {
    @ObservedObject var models: ModelManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("modelLicenseAccepted") var accepted = false
    @ViewState private var deletion: TranslationModel?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("翻訳モデル · MLX").font(.title2.bold()); Spacer(); Button("完了") { dismiss() } }
            Text("PLaMo 3 Translateの公式MLX-4bit 4サイズから選べます。まずは2Bがおすすめです。モデル取得後はオフラインで翻訳できます。").foregroundStyle(.secondary)
            HStack {
                Text("メモリ \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB").font(.caption)
                Spacer()
                Button("情報を更新") { Task { await models.refreshMetadata() } }.disabled(models.isBusy)
            }
            ForEach(models.models) { model in
                HStack(spacing: 14) {
                    Image(systemName: model.installed ? "checkmark.circle.fill" : "cube").font(.title2).foregroundStyle(model.installed ? .teal : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title).font(.headline)
                        if model.id == "31b" { Text("大容量モデル：32GB以上のメモリを推奨。空きメモリによっては動作が遅くなります。").font(.caption).foregroundStyle(.secondary) }
                        Text(model.size > 0 ? ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file) : "容量を取得中…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.installed {
                        Button(models.selectedID == model.id ? "使用中" : "使う") { models.selectedID = model.id }
                            .disabled(models.selectedID == model.id || models.isBusy)
                        Button(role: .destructive) { deletion = model } label: { Image(systemName: "trash") }.disabled(models.isBusy)
                    } else {
                        Button("ダウンロード") { Task { await models.download(model) } }.disabled(!accepted || models.isBusy)
                    }
                }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack {
                Image(systemName: "folder")
                Text(models.folder.path).font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("保存先を選択…") { models.chooseFolder() }.disabled(models.isBusy)
                Button("モデルを移動…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { Task { await models.moveModels(to: url) } }
                }.disabled(models.isBusy)
            }
            Link("PLaMo Community Licenseを読む", destination: URL(string: "https://plamo.preferredai.jp/info/plamo-community-license-ja")!)
            Toggle("ライセンスを確認し、利用条件に同意しました", isOn: $accepted)
            if models.isBusy {
                ProgressView(value: models.progress)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(models.bytesPerSecond), countStyle: .file))/秒 · 残り \(ByteCountFormatter.string(fromByteCount: models.remainingBytes, countStyle: .file))").font(.caption)
                    Spacer(); Button("一時停止") { models.pause() }
                }
            }
            if models.pausedModelID != nil && !models.isBusy { Button("ダウンロードを再開") { Task { await models.resume() } }.disabled(!accepted) }
            Text("保存先の選択は既存モデルも検出します。移動は保存済みモデルを新しいフォルダに移します。").font(.caption).foregroundStyle(.secondary)
            Text(models.status).font(.caption).foregroundStyle(.secondary)
            if let error = models.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(24).frame(width: 650)
        .confirmationDialog("このモデルを削除しますか？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("モデルを削除", role: .destructive) {
                if let model = deletion { do { try models.delete(model) } catch { models.error = error.localizedDescription } }; deletion = nil
            }
        } message: { Text("再び使う場合はダウンロードが必要です。") }
    }
}
