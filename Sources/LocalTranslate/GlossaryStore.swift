import Foundation
import Combine
import CryptoKit

struct GlossaryTerm: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var source: String
    var target: String
    var from: String = "en"
    var to: String = "ja"
}

struct Glossary: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var terms: [GlossaryTerm] = []
}

enum GlossaryFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

@MainActor final class GlossaryStore: ObservableObject {
    @Published private(set) var items: [Glossary] = []
    @Published private(set) var revision = ""
    @Published private(set) var error: String?
    @Published var selectedID: String {
        didSet { defaults.set(selectedID, forKey: "selectedGlossaryID") }
    }
    let fileURL: URL
    private let defaults: UserDefaults
    private var readFailed = false

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedID = defaults.string(forKey: "selectedGlossaryID") ?? ""
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyPLaMo")
        fileURL = folder.appendingPathComponent("glossaries.json")
        reload()
    }

    func reload() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let loaded = try JSONDecoder().decode([Glossary].self, from: data)
                try Self.validate(loaded)
                items = loaded
                revision = Self.digest(data)
            } else {
                items = []; revision = Self.digest(Data("[]".utf8))
            }
            error = nil; readFailed = false
            // Do not substitute another glossary if a selected ID disappeared.
        } catch {
            self.error = "用語集を読み込めません。保存ファイルを確認して再読み込みしてください。元のファイルは保持されています。\n\(error.localizedDescription)"
            readFailed = true
        }
    }

    func resolve(_ id: String) throws -> [GlossaryTerm] {
        if id.isEmpty { return [] }
        if readFailed { throw GlossaryFailure.invalid(error ?? "用語集を読み込めません。") }
        guard let glossary = items.first(where: { $0.id == id }) else {
            throw GlossaryFailure.invalid("選択した用語集が見つかりません。「用語集なし」または別の用語集を選び直してください。")
        }
        return glossary.terms
    }

    @discardableResult func create(name: String) throws -> String {
        let item = Glossary(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        try save(items + [item]); selectedID = item.id; return item.id
    }
    func rename(id: String, name: String) throws {
        var candidate = items
        guard let index = candidate.firstIndex(where: { $0.id == id }) else { throw missing() }
        candidate[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(candidate)
    }
    func delete(id: String) throws {
        guard items.contains(where: { $0.id == id }) else { throw missing() }
        try save(items.filter { $0.id != id })
        if selectedID == id { selectedID = "" }
    }
    func upsertTerm(glossaryID: String, term: GlossaryTerm) throws {
        var candidate = items
        guard let index = candidate.firstIndex(where: { $0.id == glossaryID }) else { throw missing() }
        var cleaned = term
        cleaned.source = term.source.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.target = term.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = candidate[index].terms.firstIndex(where: { $0.id == term.id }) { candidate[index].terms[i] = cleaned }
        else { candidate[index].terms.append(cleaned) }
        try save(candidate)
    }
    func deleteTerm(glossaryID: String, termID: String) throws {
        var candidate = items
        guard let i = candidate.firstIndex(where: { $0.id == glossaryID }), candidate[i].terms.contains(where: { $0.id == termID }) else { throw missing() }
        candidate[i].terms.removeAll { $0.id == termID }
        try save(candidate)
    }
    private func missing() -> GlossaryFailure { .invalid("編集する用語集または用語が見つかりません。") }
    private func save(_ candidate: [Glossary]) throws {
        do {
            guard !readFailed else { throw GlossaryFailure.invalid("読み込みに失敗した用語集は上書きできません。保存ファイルを修復して再読み込みしてください。") }
            try Self.validate(candidate)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(candidate)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            items = candidate; revision = Self.digest(data); error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
    nonisolated private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func validate(_ values: [Glossary]) throws {
        guard values.count <= 100, Set(values.map(\.id)).count == values.count else { throw GlossaryFailure.invalid("用語集は100件までです。IDの重複は使用できません。") }
        for g in values {
            guard !g.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !g.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, g.name.utf16.count <= 80, g.terms.count <= 5000 else {
                throw GlossaryFailure.invalid("用語集名は1〜80文字、用語は各5,000件までです。")
            }
            guard Set(g.terms.map(\.id)).count == g.terms.count else { throw GlossaryFailure.invalid("用語IDが重複しています。") }
            var duplicates = Set<String>()
            for t in g.terms {
                guard !t.id.isEmpty, !t.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !t.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      t.source.utf16.count <= 200, t.target.utf16.count <= 200,
                      PromptBuilder.languageCodes.contains(t.from), PromptBuilder.languageCodes.contains(t.to), t.from != t.to else {
                    throw GlossaryFailure.invalid("用語の原語・訳語（各200文字まで）と異なる翻訳言語を指定してください。")
                }
                guard !t.source.contains("<|plamo:"), !t.target.contains("<|plamo:") else { throw GlossaryFailure.invalid("用語にモデルの制御記号は使用できません。") }
                let key = t.from + "\u{0}" + t.to + "\u{0}" + t.source.lowercased()
                guard duplicates.insert(key).inserted else { throw GlossaryFailure.invalid("同じ翻訳方向の原語が重複しています。大文字・小文字は区別されません。") }
            }
        }
    }
    nonisolated static func matchingTerms(_ terms: [GlossaryTerm], text: String, source: String?, target: String) throws -> [GlossaryTerm] {
        let found = terms.filter { $0.to == target && (source == nil || $0.from == source) && text.range(of: $0.source, options: .caseInsensitive) != nil }
        guard found.count <= 32, found.reduce(0, { $0 + $1.source.utf16.count + $1.target.utf16.count }) <= 2000 else {
            throw GlossaryFailure.invalid("一致する用語が多すぎます（32語・原語と訳語の合計2,000文字まで）。原文を分割して翻訳してください。")
        }
        return found
    }
}
