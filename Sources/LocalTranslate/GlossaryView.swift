import SwiftUI

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

    private var current: Glossary? { store.items.first { $0.id == editingID } }
    private var filteredGlossaries: [Glossary] { store.items.filter { glossarySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(glossarySearch) } }
    private var filteredTerms: [GlossaryTerm] { (current?.terms ?? []).filter { termSearch.isEmpty || $0.source.localizedCaseInsensitiveContains(termSearch) || $0.target.localizedCaseInsensitiveContains(termSearch) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("用語集").font(.title2.bold())
                Spacer()
                Button("再読み込み") { store.reload(); loadGlossary() }
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("用語をモデルへの指示に使います。訳語が必ず採用されるとは限りません。")
                .font(.callout).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("用語集を検索", text: $glossarySearch)
                    List(selection: $editingID) {
                        ForEach(filteredGlossaries) { glossary in
                            VStack(alignment: .leading) {
                                Text(glossary.name)
                                Text("\(glossary.terms.count)語" + (glossary.id == store.selectedID ? " · 翻訳に使用中" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.tag(glossary.id)
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
            if let error = store.error, !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.red) }
        }
        .padding(20).frame(minWidth: 760, idealWidth: 900, minHeight: 530, idealHeight: 630)
        .onAppear { editingID = store.items.contains(where: { $0.id == store.selectedID }) ? store.selectedID : store.items.first?.id; loadGlossary() }
        .onChange(of: editingID) { _, _ in loadGlossary() }
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
    private func perform(_ action: () throws -> Void) { do { try action(); message = "" } catch { message = error.localizedDescription } }
    private func newTerm() { selectedTermID = nil; term = GlossaryTerm(source: "", target: "", from: term.from, to: term.to) }
    private func loadGlossary() { name = current?.name ?? ""; selectedTermID = nil; termSearch = ""; newTerm() }
}
