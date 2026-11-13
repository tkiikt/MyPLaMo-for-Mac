import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GlossaryView: View {
    @ObservedObject var store: GlossaryStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var editingID: String?
    @ViewState private var selectedTermID: String?
    @ViewState private var glossarySearch = ""
    @ViewState private var termSearch = ""
    @ViewState private var name = ""
    @ViewState private var term = GlossaryTerm(source: "", target: "")
    @ViewState private var message = ""
    @ViewState private var deletingGlossary = false
    @ViewState private var deletingTerm = false

    @ViewState private var backupBusy = false
    @ViewState private var restorePlan: GlossaryRestorePlan?
    @ViewState private var success = ""

    private var current: Glossary? { store.items.first { Data($0.id.utf8) == editingID.map { Data($0.utf8) } } }
    private var editingKey: Binding<Data?> {
        Binding(get: { editingID.map { Data($0.utf8) } },
                set: { editingID = $0.flatMap { String(data: $0, encoding: .utf8) } })
    }
    private var filteredGlossaries: [Glossary] { store.items.filter { glossarySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(glossarySearch) } }
    private var filteredTerms: [GlossaryTerm] { (current?.terms ?? []).filter { termSearch.isEmpty || $0.source.localizedCaseInsensitiveContains(termSearch) || $0.target.localizedCaseInsensitiveContains(termSearch) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("用語集").font(.title2.bold())
                Spacer()
                Button("バックアップ…") { backup() }.disabled(store.items.isEmpty)
                Button("復元…") { chooseRestore() }
                Button("再読み込み") { store.reload(); loadGlossary() }
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("用語をモデルへの指示に使います。訳語が必ず採用されるとは限りません。")
                .font(.callout).foregroundStyle(.secondary)
            Text("バックアップは保存済みの全用語集が対象です。編集中の内容は先に保存してください。")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("用語集を検索", text: $glossarySearch)
                    List(selection: editingKey) {
                        ForEach(filteredGlossaries, id: \.idBytes) { glossary in
                            VStack(alignment: .leading) {
                                Text(glossary.name)
                                Text("\(glossary.terms.count)語" + (glossary.idBytes == Data(store.selectedID.utf8) ? " · 翻訳に使用中" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.tag(glossary.idBytes)
                        }
                    }.frame(minHeight: 220)
                    HStack {
                        Button("新規作成") { perform { editingID = try store.create(name: "新しい用語集"); loadGlossary() } }
                        Button("削除") { deletingGlossary = true }.disabled(current == nil)
                    }
                    Button("用語集を使わない") { store.selectedID = "" }
                }.frame(minWidth: 190, idealWidth: 210, maxWidth: 280).padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 10) {
                    if let current {
                        HStack {
                            TextField("用語集名（80文字まで）", text: $name)
                            Button("名前を保存") { perform { try store.rename(id: current.id, name: name) } }
                            Button("翻訳に使う") { store.selectedID = current.id }
                        }
                        TextField("原語・訳語を検索", text: $termSearch)
                        List(selection: $selectedTermID) {
                            ForEach(filteredTerms) { entry in
                                HStack(alignment: .top) {
                                    Text(entry.source).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Text(entry.target).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(entry.from) → \(entry.to)").font(.caption).foregroundStyle(.secondary)
                                }.tag(entry.id)
                            }
                        }.frame(minHeight: 130)
                        HStack {
                            Button("新しい用語") { newTerm() }
                            Button("用語を削除") { deletingTerm = true }.disabled(selectedTermID == nil)
                            Spacer()
                            Text("\(current.terms.count) / 5,000語").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Picker("翻訳元", selection: $term.from) {
                                ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            Picker("翻訳先", selection: $term.to) {
                                ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                            }
                        }
                        TextField("原語（200文字まで）", text: $term.source)
                        TextField("訳語（200文字まで）", text: $term.target)
                        HStack {
                            Spacer()
                            Button(selectedTermID == nil ? "用語を追加" : "用語の変更を保存") {
                                perform {
                                    try store.upsertTerm(glossaryID: current.id, term: term)
                                    selectedTermID = term.id
                                }
                            }.disabled(term.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || term.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        Spacer()
                        Text("用語集を選ぶか、新規作成してください。")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    }
                }.frame(minWidth: 450).padding(.leading, 8)
            }
            if backupBusy { ProgressView("処理中…").controlSize(.small) }
            if !success.isEmpty { Text(success).font(.callout).textSelection(.enabled) }
            if let error = store.error, !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.red) }
        }
        .disabled(backupBusy || restorePlan != nil)
        .interactiveDismissDisabled(backupBusy || restorePlan != nil)
        .sheet(isPresented: Binding(get: { restorePlan != nil }, set: { if !$0 { restorePlan = nil } })) {
            if let plan = restorePlan {
                VStack(alignment: .leading, spacing: 16) {
                    Text("用語集を追加して復元").font(.title2.bold())
                    Text("追加する用語集：\(plan.additions.count)件 ／ 用語：\(plan.totalTermCount)語")
                    Text("同じ内容でスキップ：\(plan.skippedCount)件")
                    if !plan.additions.isEmpty {
                        Text(plan.additions.prefix(5).map(\.name).joined(separator: "\n") + (plan.additions.count > 5 ? "\nほか\(plan.additions.count - 5)件" : ""))
                            .lineLimit(10).textSelection(.enabled)
                    }
                    Text("現在の用語集は残ります。同じ名前でも内容が異なる場合は、別の用語集として追加します。")
                    Text("翻訳に使用中の用語集は変更しません。").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("キャンセル", role: .cancel) { restorePlan = nil }.keyboardShortcut(.cancelAction)
                        Button("追加して復元") { applyRestore(plan) }
                            .keyboardShortcut(.defaultAction).disabled(plan.additions.isEmpty)
                    }
                }.padding(24).frame(width: 500).disabled(false)
            }
        }
        .padding(20).frame(minWidth: 760, idealWidth: 900, minHeight: 530, idealHeight: 630)
        .onAppear { editingID = store.items.contains(where: { $0.idBytes == Data(store.selectedID.utf8) }) ? store.selectedID : store.items.first?.id; loadGlossary() }
        .onChange(of: editingID.map { Data($0.utf8) }) { _, _ in loadGlossary() }
        .onChange(of: selectedTermID) { _, id in if let entry = current?.terms.first(where: { $0.id == id }) { term = entry } }
        .alert("用語集を削除しますか？", isPresented: $deletingGlossary) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) { if let id = editingID { perform { try store.delete(id: id); editingID = nil; loadGlossary() } } }
        } message: { Text("この用語集に登録した用語も削除されます。") }
        .alert("選択した用語を削除しますか？", isPresented: $deletingTerm) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) { if let id = editingID, let termID = selectedTermID { perform { try store.deleteTerm(glossaryID: id, termID: termID); newTerm() } } }
        }
    }
    private func backup() {
        guard !backupBusy else { return }
        message = ""; success = ""
        do {
            let snapshot = try store.backupSnapshot()
            guard !snapshot.isEmpty else { return }
            backupBusy = true
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "myplamo-glossary") ?? .data]
            panel.canCreateDirectories = true
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            panel.nameFieldStringValue = "MyPLaMo-用語集-\(formatter.string(from: Date())).myplamo-glossary"
            panel.message = "保存済みの全用語集をバックアップします。"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { backupBusy = false; return }
                Task { @MainActor in
                    defer { backupBusy = false }
                    do {
                        try await Task.detached { try GlossaryBackup.write(snapshot, to: url) }.value
                        success = "\(snapshot.count)件の用語集を保存しました。\n\(url.path)"
                    } catch { message = error.localizedDescription }
                }
            }
        } catch { message = error.localizedDescription }
    }
    private func chooseRestore() {
        guard !backupBusy else { return }
        message = ""; success = ""; backupBusy = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "myplamo-glossary") ?? .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "復元する用語集のバックアップを選んでください。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { backupBusy = false; return }
            Task { @MainActor in
                defer { backupBusy = false }
                do {
                    let items = try await Task.detached { try GlossaryBackup.read(from: url) }.value
                    restorePlan = try store.planRestore(items)
                } catch { message = error.localizedDescription }
            }
        }
    }
    private func applyRestore(_ plan: GlossaryRestorePlan) {
        guard !backupBusy else { return }
        restorePlan = nil; backupBusy = true; message = ""; success = ""
        Task { @MainActor in
            defer { backupBusy = false }
            do {
                try await store.restoreAsync(plan)
                glossarySearch = ""; editingID = plan.additions.first?.id; loadGlossary()
                success = "\(plan.additions.count)件を追加し、\(plan.skippedCount)件をスキップしました。"
            } catch { message = error.localizedDescription }
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); message = "" } catch { message = error.localizedDescription } }
    private func newTerm() { selectedTermID = nil; term = GlossaryTerm(source: "", target: "", from: term.from, to: term.to) }
    private func loadGlossary() { name = current?.name ?? ""; selectedTermID = nil; termSearch = ""; newTerm() }
}
