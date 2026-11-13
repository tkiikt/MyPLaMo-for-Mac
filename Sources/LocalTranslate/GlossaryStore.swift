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
    var idBytes: Data { Data(id.utf8) }
}

struct GlossaryRestorePlan: Sendable {
    let additions: [Glossary]
    let skippedCount: Int
    fileprivate let baseRevision: String
    var totalTermCount: Int { additions.reduce(0) { $0 + $1.terms.count } }
}

enum GlossaryFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

@MainActor final class GlossaryStore: ObservableObject {
    @Published private(set) var items: [Glossary] = []
    @Published private(set) var revision = ""
    @Published private(set) var error: String?
    @Published private(set) var isRestoring = false
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
        guard !isRestoring else { return }
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
        guard let glossary = items.first(where: { Self.sameBytes($0.id, id) }) else {
            throw GlossaryFailure.invalid("選択した用語集が見つかりません。「用語集なし」または別の用語集を選び直してください。")
        }
        return glossary.terms
    }

    /// A value snapshot: editor fields are intentionally not committed here.
    func backupSnapshot() throws -> [Glossary] {
        try requireReadable()
        try Self.validate(items)
        return items
    }

    func planRestore(_ backup: [Glossary]) throws -> GlossaryRestorePlan {
        try requireReadable()
        try Self.validate(backup)
        var unmatched = items
        var fingerprints = items.map(Self.contentDigest)
        var occupiedIDs = Set(items.map { Data($0.id.utf8) })
        var additions: [Glossary] = []
        var skipped = 0
        for value in backup {
            let fingerprint = Self.contentDigest(value)
            if let index = unmatched.indices.first(where: { fingerprints[$0] == fingerprint && Self.sameContent(unmatched[$0], value) }) {
                unmatched.remove(at: index)
                fingerprints.remove(at: index)
                skipped += 1
            } else {
                var addition = value
                while occupiedIDs.contains(Data(addition.id.utf8)) { addition.id = UUID().uuidString }
                occupiedIDs.insert(Data(addition.id.utf8))
                additions.append(addition)
            }
        }
        try Self.validate(items + additions)
        return GlossaryRestorePlan(additions: additions, skippedCount: skipped, baseRevision: revision)
    }

    /// Never changes the glossary selected for translation, including on failure.
    func restore(_ plan: GlossaryRestorePlan) throws {
        try requireReadable()
        guard plan.baseRevision == revision else {
            throw GlossaryFailure.invalid("確認中に用語集が変更されました。復元ファイルを選び直して内容を確認してください。")
        }
        guard !plan.additions.isEmpty else { return }
        try save(items + plan.additions)
    }

    /// File encoding and atomic writing run off the UI thread. Concurrent mutations
    /// are rejected until the candidate is either committed or discarded.
    func restoreAsync(_ plan: GlossaryRestorePlan) async throws {
        try requireReadable()
        guard plan.baseRevision == revision else {
            throw GlossaryFailure.invalid("確認中に用語集が変更されました。復元ファイルを選び直して内容を確認してください。")
        }
        guard !plan.additions.isEmpty else { return }
        let candidate = items + plan.additions
        let destination = fileURL
        isRestoring = true
        defer { isRestoring = false }
        do {
            let newRevision = try await Task.detached(priority: .userInitiated) {
                try Self.writeCandidate(candidate, to: destination)
            }.value
            items = candidate; revision = newRevision; error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private func requireReadable() throws {
        guard !isRestoring else { throw GlossaryFailure.invalid("用語集を復元しています。完了してから操作してください。") }
        guard !readFailed else {
            throw GlossaryFailure.invalid("読み込みに失敗した用語集は変更できません。保存ファイルを修復して再読み込みしてください。")
        }
    }
    nonisolated static func sameContent(_ lhs: Glossary, _ rhs: Glossary) -> Bool {
        guard sameBytes(lhs.name, rhs.name), lhs.terms.count == rhs.terms.count else { return false }
        return zip(lhs.terms, rhs.terms).allSatisfy { a, b in
            sameBytes(a.source, b.source) && sameBytes(a.target, b.target) &&
                sameBytes(a.from, b.from) && sameBytes(a.to, b.to)
        }
    }
    nonisolated static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    @discardableResult func create(name: String) throws -> String {
        let item = Glossary(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        try save(items + [item]); selectedID = item.id; return item.id
    }
    func rename(id: String, name: String) throws {
        var candidate = items
        guard let index = candidate.firstIndex(where: { Self.sameBytes($0.id, id) }) else { throw missing() }
        candidate[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(candidate)
    }
    func delete(id: String) throws {
        guard items.contains(where: { Self.sameBytes($0.id, id) }) else { throw missing() }
        try save(items.filter { !Self.sameBytes($0.id, id) })
        if Self.sameBytes(selectedID, id) { selectedID = "" }
    }
    func upsertTerm(glossaryID: String, term: GlossaryTerm) throws {
        var candidate = items
        guard let index = candidate.firstIndex(where: { Self.sameBytes($0.id, glossaryID) }) else { throw missing() }
        var cleaned = term
        cleaned.source = term.source.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.target = term.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = candidate[index].terms.firstIndex(where: { Self.sameBytes($0.id, term.id) }) { candidate[index].terms[i] = cleaned }
        else { candidate[index].terms.append(cleaned) }
        try save(candidate)
    }
    func deleteTerm(glossaryID: String, termID: String) throws {
        var candidate = items
        guard let i = candidate.firstIndex(where: { Self.sameBytes($0.id, glossaryID) }), candidate[i].terms.contains(where: { Self.sameBytes($0.id, termID) }) else { throw missing() }
        candidate[i].terms.removeAll { Self.sameBytes($0.id, termID) }
        try save(candidate)
    }
    private func missing() -> GlossaryFailure { .invalid("編集する用語集または用語が見つかりません。") }
    private func save(_ candidate: [Glossary]) throws {
        do {
            try requireReadable()
            let newRevision = try Self.writeCandidate(candidate, to: fileURL)
            items = candidate; revision = newRevision; error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
    nonisolated private static func writeCandidate(_ candidate: [Glossary], to url: URL) throws -> String {
        try validate(candidate)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(candidate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return digest(data)
    }
    nonisolated private static func contentDigest(_ glossary: Glossary) -> Data {
        var digest = SHA256()
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { digest.update(data: Data($0)) }
            digest.update(data: bytes)
        }
        append(glossary.name)
        for term in glossary.terms { append(term.source); append(term.target); append(term.from); append(term.to) }
        return Data(digest.finalize())
    }
    nonisolated private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func validate(_ values: [Glossary]) throws {
        guard values.count <= 100, Set(values.map { Data($0.id.utf8) }).count == values.count else { throw GlossaryFailure.invalid("用語集は100件までです。IDの重複は使用できません。") }
        for g in values {
            guard !g.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !g.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, g.name.utf16.count <= 80, g.terms.count <= 5000 else {
                throw GlossaryFailure.invalid("用語集名は1〜80文字、用語は各5,000件までです。")
            }
            guard Set(g.terms.map { Data($0.id.utf8) }).count == g.terms.count else { throw GlossaryFailure.invalid("用語IDが重複しています。") }
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
