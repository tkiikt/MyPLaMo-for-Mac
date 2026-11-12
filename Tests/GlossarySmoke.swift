import Foundation

@main struct GlossarySmoke {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyPLaMo-glossary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MyPLaMo-glossary-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL \(label)") }; checks += 1; print("PASS \(label)")
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAIL accepted \(label)") } catch { checks += 1; print("PASS \(label)") }
        }
        let store = GlossaryStore(directory: directory, defaults: defaults)
        let id = try store.create(name: "Software")
        let term = GlossaryTerm(source: "dashboard", target: "管理画面")
        try store.upsertTerm(glossaryID: id, term: term)
        let revision = store.revision
        check(store.selectedID == id, "creation persists selected glossary")
        let loaded = GlossaryStore(directory: directory, defaults: defaults)
        check(loaded.items == store.items && loaded.revision == revision && loaded.selectedID == id, "atomic saved snapshot reloads with stable IDs and revision")
        try store.rename(id: id, name: "Manual")
        check(store.revision != revision && store.items.first?.id == id, "rename changes revision and preserves ID")
        let before = try Data(contentsOf: store.fileURL)
        rejects("case-insensitive duplicate rejected") { try store.upsertTerm(glossaryID: id, term: GlossaryTerm(source: "DASHBOARD", target: "画面")) }
        let after = try Data(contentsOf: store.fileURL)
        check(before == after && store.items[0].terms.count == 1, "invalid save preserves file and snapshot")
        rejects("same language rejected") { try store.upsertTerm(glossaryID: id, term: GlossaryTerm(source: "term", target: "訳", from: "ja", to: "ja")) }
        rejects("unknown language rejected") { try store.upsertTerm(glossaryID: id, term: GlossaryTerm(source: "term", target: "訳", from: "invalid")) }
        rejects("control token rejected") { try store.upsertTerm(glossaryID: id, term: GlossaryTerm(source: "<|plamo:tag|>", target: "訳")) }
        rejects("empty term rejected") { try store.upsertTerm(glossaryID: id, term: GlossaryTerm(source: "  ", target: "訳")) }
        rejects("UTF16 limit enforced") { try store.upsertTerm(glossaryID: id, term: GlossaryTerm(source: String(repeating: "😀", count: 101), target: "訳")) }
        rejects("name limit enforced") { _ = try store.create(name: String(repeating: "a", count: 81)) }
        rejects("missing ID is not substituted") { _ = try store.resolve("missing-id") }
        check(try store.resolve("").isEmpty, "none resolves empty snapshot")
        let terms = [term, GlossaryTerm(source: "dashboard", target: "tableau", from: "en", to: "fr"), GlossaryTerm(source: "other", target: "別")]
        check(try GlossaryStore.matchingTerms(terms, text: "DASHBOARD", source: "en", target: "ja") == [term], "case-insensitive occurrence and direction filter")
        check(try GlossaryStore.matchingTerms(terms, text: "dashboard", source: "fr", target: "ja").isEmpty, "source mismatch excluded")
        check(try GlossaryStore.matchingTerms(terms, text: "dashboard", source: nil, target: "ja") == [term], "automatic source matches target direction")
        let tooMany = (0..<33).map { GlossaryTerm(source: "x\($0)", target: "訳") }
        rejects("32 matching term cap") { _ = try GlossaryStore.matchingTerms(tooMany, text: tooMany.map(\.source).joined(separator: " "), source: nil, target: "ja") }
        let tooLong = (0..<10).map { GlossaryTerm(source: "term\($0)", target: String(repeating: "訳", count: 200)) }
        rejects("2000 matching characters cap") { _ = try GlossaryStore.matchingTerms(tooLong, text: tooLong.map(\.source).joined(separator: " "), source: nil, target: "ja") }
        rejects("100 glossary cap") { try GlossaryStore.validate((0..<101).map { Glossary(name: "\($0)") }) }
        rejects("5000 term cap") { try GlossaryStore.validate([Glossary(name: "Big", terms: (0..<5001).map { GlossaryTerm(source: "x\($0)", target: "訳") })]) }
        try store.delete(id: id)
        check(store.selectedID.isEmpty && store.items.isEmpty, "deleting active glossary clears selection")
        defaults.set("missing-id", forKey: "selectedGlossaryID")
        let missing = GlossaryStore(directory: directory, defaults: defaults)
        check(missing.selectedID == "missing-id", "stale persisted selection never selects unrelated glossary")
        try Data("broken file".utf8).write(to: store.fileURL)
        let broken = GlossaryStore(directory: directory, defaults: defaults)
        check(broken.error != nil, "broken file reports failure")
        rejects("broken file cannot be overwritten") { _ = try broken.create(name: "New") }
        check(try String(contentsOf: store.fileURL, encoding: .utf8) == "broken file", "broken bytes preserved")
        try Data("[]".utf8).write(to: store.fileURL); broken.reload()
        _ = try broken.create(name: "Recovered")
        check(broken.error == nil && broken.items.count == 1, "explicit reload recovers after repair")
        let blocked = directory.appendingPathComponent("not-a-folder")
        try Data("keep".utf8).write(to: blocked)
        let failure = GlossaryStore(directory: blocked, defaults: defaults)
        rejects("write failure is surfaced") { _ = try failure.create(name: "Must not publish") }
        check(failure.items.isEmpty && failure.error != nil, "write failure leaves published state unchanged")
        print("ALL \(checks) GLOSSARY CHECKS PASSED")
    }
}
