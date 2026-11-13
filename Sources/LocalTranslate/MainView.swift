import SwiftUI
import AppKit

struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelManager
    @ObservedObject var engine: InferenceEngine
    let integration: DesktopIntegration
    @ViewState private var confirmInsert = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MyPLaMo for Mac").font(.title2.bold())
                    Label("このMacだけで翻訳", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.showHistory.toggle() } label: { Label("履歴", systemImage: "clock.arrow.circlepath") }
                Button { state.showModels = true } label: { Label("モデル", systemImage: "externaldrive") }.disabled(engine.isBusy || state.desktopBusy)
                Button { state.showSettings = true } label: { Image(systemName: "gearshape") }.help("設定")
            }.padding(22)
            HStack {
                Toggle("Chromeからの翻訳を受け付ける", isOn: Binding(get: { state.chromeEnabled }, set: { state.setChromeEnabled($0) }))
                    .toggleStyle(.switch)
                Text("Built with PLaMo · MLX").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 22).padding(.bottom, 12)
            ChromeStatusView(bridge: state.bridge)
            Divider()
            HStack(spacing: 16) {
                languagePicker("翻訳元", selection: $state.source, automatic: true)
                Button { state.swap() } label: { Image(systemName: "arrow.left.arrow.right") }.help("言語と文章を入れ替え")
                    .disabled(engine.isBusy || state.output.isEmpty)
                languagePicker("翻訳先", selection: $state.target, automatic: false)
            }.padding(.horizontal, 24).padding(.vertical, 18)
            TranslationOptionsView(state: state, glossaries: state.glossaries)
                .padding(.horizontal, 24).padding(.bottom, 12)
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("原文").font(.headline); Spacer(); Button("貼り付け") { state.paste() }; Button("クリア") { state.input = "" } }
                    TextEditor(text: $state.input).font(.system(size: 17)).scrollContentBackground(.hidden).accessibilityLabel("翻訳する文章")
                    Text("\(state.input.count) / 6,000文字").font(.caption).foregroundStyle(state.input.count > 6000 ? .red : .secondary)
                }.padding(18).frame(minWidth: 310)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("訳文").font(.headline); Spacer()
                        Button("コピー") { state.copy() }.disabled(state.output.isEmpty)
                        if state.originApp != nil { Button("元のアプリへ挿入…") { confirmInsert = true }.disabled(state.output.isEmpty || engine.isBusy) }
                    }
                    ScrollView {
                        Text(state.output.isEmpty ? "翻訳結果がここに表示されます" : state.output)
                            .font(.system(size: 17)).foregroundStyle(state.output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }.frame(maxHeight: .infinity)
                    if state.target == "ja" {
                        Picker("文体", selection: $state.style) { Text("です・ます").tag("polite"); Text("だ・である").tag("plain") }.pickerStyle(.segmented).frame(maxWidth: 280)
                    }
                }.padding(18).frame(minWidth: 310)
            }.background(.background).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary)).padding(.horizontal, 22)
            HStack(spacing: 12) {
                Circle().fill(models.selectedModelURL == nil ? Color.orange : Color.teal).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(models.selectedModelURL == nil ? "モデルを選択して始めましょう" : "PLaMo 3 Translate · \(models.selectedID.uppercased()) · MLX · \(state.useGPU ? "Apple GPU" : "CPU")").font(.caption)
                    Text(state.desktopBusy ? state.progress : engine.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.desktopBusy {
                    ProgressView().controlSize(.small)
                    Button("中止") { state.cancel() }
                } else {
                    Button { state.translate() } label: { Label("翻訳する", systemImage: "arrow.right").padding(.horizontal, 14).padding(.vertical, 5) }
                        .buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut(.return, modifiers: .command)
                        .disabled(state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.input.count > 6000)
                }
            }.padding(22)
            if !state.message.isEmpty { Text(state.message).font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 22).padding(.bottom, 14) }
        }
        .onChange(of: models.selectedID) { _, _ in engine.shutdown() }
        .onChange(of: models.folder) { _, _ in engine.shutdown() }
        .onChange(of: models.selectedModelURL) { _, url in if url == nil { engine.shutdown() } }
        .sheet(isPresented: $state.showSettings) { VStack { HStack { Text("設定").font(.title2.bold()); Spacer(); Button("閉じる") { state.showSettings = false } }.padding(); AppSettings(state: state, integration: integration) } }
        .sheet(isPresented: $state.showModels) { ModelView(models: models) }
        .sheet(isPresented: $state.showHistory) { historyView }
        .sheet(isPresented: $state.showGlossaries) { GlossaryView(store: state.glossaries) }
        .confirmationDialog("\(state.originApp?.localizedName ?? "元のアプリ")に訳文を貼り付けますか？", isPresented: $confirmInsert) {
            Button("貼り付ける") {
                guard let app = state.originApp else { return }
                Task { if !(await integration.insert(state.output, into: app)) { state.message = "挿入できませんでした。訳文をコピーして貼り付けてください。" } }
            }
        } message: { Text("そのアプリで現在選択されている文章を置き換えます。") }
    }
    func languagePicker(_ title: String, selection: Binding<String>, automatic: Bool) -> some View {
        Picker(title, selection: selection) {
            if automatic { Text("自動検出").tag("auto") }
            ForEach(languages, id: \.0) { code, name in Text(name).tag(code) }
        }.frame(maxWidth: .infinity)
    }
    var historyView: some View {
        VStack(alignment: .leading) {
            HStack { Text("翻訳履歴").font(.title2.bold()); Spacer(); Button("閉じる") { state.showHistory = false } }
            Toggle("履歴をこのMacに保存", isOn: $state.saveHistory).onChange(of: state.saveHistory) { _, _ in state.persistHistory() }
            if state.history.isEmpty { ContentUnavailableView("履歴はありません", systemImage: "clock", description: Text("保存を有効にすると、以降の翻訳を最大100件保存します。")) }
            List(state.history) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.source).lineLimit(2).foregroundStyle(.secondary)
                    Text(item.translation).lineLimit(3)
                    HStack {
                        Text(item.date, style: .date).font(.caption)
                        Spacer()
                        Button("原文を使う") { state.input = item.source; state.target = item.target; state.showHistory = false }
                        Button("訳文をコピー") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.translation, forType: .string) }
                    }
                }.padding(.vertical, 6)
            }
            Button("履歴をすべて削除", role: .destructive) { state.clearHistory() }
        }.padding(24).frame(width: 620, height: 480)
    }
}

struct ChromeStatusView: View {
    @ObservedObject var bridge: ChromeBridge
    var body: some View {
        if let error = bridge.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 22).padding(.bottom, 8) }
        else if bridge.isRunning { Text(bridge.status).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8) }
    }
}


struct TranslationOptionsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var glossaries: GlossaryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("形式", selection: $state.documentFormat) {
                    Text("自動判定").tag(DocumentFormat.automatic)
                    Text("テキスト").tag(DocumentFormat.text)
                    Text("Markdown").tag(DocumentFormat.markdown)
                    Text("JSON").tag(DocumentFormat.json)
                    Text("YAML").tag(DocumentFormat.yaml)
                }.frame(maxWidth: 240)
                Picker("用語集", selection: Binding(get: { Data(glossaries.selectedID.utf8) }, set: { glossaries.selectedID = String(decoding: $0, as: UTF8.self) })) {
                    Text("用語集なし").tag(Data())
                    ForEach(glossaries.items, id: \.idBytes) { item in Text(item.name).tag(item.idBytes) }
                    if !glossaries.selectedID.isEmpty && !glossaries.items.contains(where: { $0.idBytes == Data(glossaries.selectedID.utf8) }) {
                        Text("選択した用語集が見つかりません").tag(Data(glossaries.selectedID.utf8))
                    }
                }.frame(maxWidth: .infinity)
                Button("用語集を管理…") { state.showGlossaries = true }
            }.disabled(state.desktopBusy)
            HStack {
                Toggle("文脈を考慮", isOn: $state.useContext).toggleStyle(.checkbox)
                TextField("参照する文脈（任意・800文字まで）", text: $state.referenceContext)
                    .textFieldStyle(.roundedBorder).disabled(!state.useContext)
            }.disabled(state.desktopBusy)
            if let error = glossaries.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
