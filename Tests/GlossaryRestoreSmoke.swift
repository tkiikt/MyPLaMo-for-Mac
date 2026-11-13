import Foundation

@main struct GlossaryRestoreSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyPLaMo-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MyPLaMo-restore-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL \(label)") }; checks += 1; print("PASS \(label)")
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAIL accepted \(label)") } catch { checks += 1; print("PASS \(label)") }
        }
        func fresh(_ name: String) -> GlossaryStore { GlossaryStore(directory: root.appendingPathComponent(name), defaults: defaults) }
        let term = GlossaryTerm(source: "cat,\"😀\"\n", target: " ネコちゃん\n", from: "en", to: "ja")
        let a = Glossary(id: "animals", name: "動物", terms: [term, GlossaryTerm(source: "cat,\"😀\"\n", target: "ねこ", from: "fr", to: "ja")])
        let empty = Glossary(id: "empty", name: "空の用語集", terms: [])
        let store = fresh("normal")
        store.selectedID = "existing-selection"
        let beforeRevision = store.revision
        let plan = try store.planRestore([a, empty])
        check(plan.additions.map(\.id) == ["animals", "empty"] && plan.totalTermCount == 2 && plan.skippedCount == 0, "restore plan retains IDs, ordering and empty glossary")
        check(store.items.isEmpty && store.revision == beforeRevision && !FileManager.default.fileExists(atPath: store.fileURL.path), "planning is read-only")
        try await store.restoreAsync(plan)
        check(store.items == [a, empty] && store.selectedID == "existing-selection" && store.revision != beforeRevision, "async restore commits all data and preserves translation selection")
        check(!store.isRestoring && store.error == nil, "async restore releases mutation gate")
        check(try store.backupSnapshot() == [a, empty], "backup uses entire saved snapshot")
        let persisted = try Data(contentsOf: store.fileURL)
        let revision = store.revision
        var regenerated = a
        regenerated.id = "different-glossary-id"
        regenerated.terms = a.terms.map { GlossaryTerm(source: $0.source, target: $0.target, from: $0.from, to: $0.to) }
        let repeated = try store.planRestore([regenerated, empty])
        check(repeated.additions.isEmpty && repeated.skippedCount == 2, "content matching ignores glossary and term IDs")
        try await store.restoreAsync(repeated)
        check(try Data(contentsOf: store.fileURL) == persisted && store.revision == revision, "zero additions performs no write")
        var twin = a; twin.id = "other"
        for count in 0...2 {
            let duplicates = fresh("multiplicity-\(count)")
            let existing = Array([a, twin].prefix(count))
            try await duplicates.restoreAsync(duplicates.planRestore(existing))
            let result = try duplicates.planRestore([a, twin])
            check(result.additions.count == 2 - count && result.skippedCount == count, "one-to-one duplicate matching with \(count) existing")
        }
        var changed = a; changed.terms[0].target = "別の内容"
        let collision = try store.planRestore([changed])
        check(collision.additions.count == 1 && collision.additions[0].id != a.id && collision.additions[0].name == a.name, "ID collision generates ID without renaming content")
        try await store.restoreAsync(collision)
        check(store.items[0] == a && store.items[2].terms == changed.terms, "ID collision preserves original")
        check(try store.planRestore([changed]).additions.isEmpty, "repeated colliding restore skips prior copy")
        let composed = Glossary(id: "é", name: "é", terms: [GlossaryTerm(source: "café", target: "訳")])
        let decomposed = Glossary(id: "e\u{301}", name: "e\u{301}", terms: [GlossaryTerm(source: "cafe\u{301}", target: "訳")])
        let unicode = fresh("unicode")
        try await unicode.restoreAsync(unicode.planRestore([composed, decomposed]))
        check(unicode.items.count == 2 && unicode.items[0].idBytes != unicode.items[1].idBytes, "opaque IDs and content compare exact UTF8 bytes")
        check(try unicode.resolve(decomposed.id)[0].source.utf8.elementsEqual(decomposed.terms[0].source.utf8), "opaque Unicode ID resolves exact glossary")
        let variants = [Glossary(id: "case", name: "動物", terms: [GlossaryTerm(source: "Cat", target: "猫")]),
                        Glossary(id: "space", name: " 動物", terms: a.terms),
                        Glossary(id: "order", name: "動物", terms: a.terms.reversed())]
        check(try store.planRestore(variants).additions.count == 3, "case, whitespace and term order distinguish content")
        let stale = try store.planRestore([Glossary(id: "new", name: "New")])
        try store.rename(id: empty.id, name: "Changed")
        do { try await store.restoreAsync(stale); fatalError("FAIL stale accepted") }
        catch { check(store.items.count == 3, "stale confirmation rejected") }
        let full = fresh("full")
        try await full.restoreAsync(full.planRestore((0..<100).map { Glossary(id: "g\($0)", name: "\($0)") }))
        rejects("combined 101 glossary limit") { _ = try full.planRestore([Glossary(id: "new", name: "New")]) }
        rejects("duplicate backup IDs") { _ = try store.planRestore([a, a]) }
        rejects("backup invalid language") { _ = try store.planRestore([Glossary(name: "Bad", terms: [GlossaryTerm(source: "x", target: "y", from: "unknown")])]) }
        let broken = fresh("broken")
        try FileManager.default.createDirectory(at: broken.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let safePlan = try broken.planRestore([a])
        try Data("broken".utf8).write(to: broken.fileURL)
        broken.reload()
        rejects("broken store cannot plan restore") { _ = try broken.planRestore([a]) }
        rejects("broken store cannot export misleading snapshot") { _ = try broken.backupSnapshot() }
        do { try await broken.restoreAsync(safePlan); fatalError("FAIL corrupt overwritten") }
        catch { check(try Data(contentsOf: broken.fileURL) == Data("broken".utf8), "async restore cannot bypass corrupt store protection") }
        let blocked = fresh("write-failure")
        let first = try blocked.create(name: "Original")
        let originalItems = blocked.items, originalRevision = blocked.revision
        let failPlan = try blocked.planRestore([a])
        let originalFile = root.appendingPathComponent("preserved-original.json")
        try FileManager.default.moveItem(at: blocked.fileURL, to: originalFile)
        try FileManager.default.createDirectory(at: blocked.fileURL, withIntermediateDirectories: false)
        let sentinel = blocked.fileURL.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        do { try await blocked.restoreAsync(failPlan); fatalError("FAIL write accepted") }
        catch {
            check(blocked.items == originalItems && blocked.selectedID == first && blocked.revision == originalRevision && !blocked.isRestoring, "write failure preserves memory, revision and selection")
            check(try Data(contentsOf: sentinel) == Data("keep".utf8), "failed replacement preserves destination")
        }
        let concurrent = fresh("concurrent")
        let many = Glossary(id: "many", name: "Large", terms: (0..<5000).map { GlossaryTerm(source: "term\($0)", target: String(repeating: "訳", count: 200)) })
        let largePlan = try concurrent.planRestore([many])
        let restoring = Task { try await concurrent.restoreAsync(largePlan) }
        await Task.yield()
        check(concurrent.isRestoring, "async restore holds mutation gate during file work")
        rejects("concurrent edit cannot race restore") { _ = try concurrent.create(name: "Unexpected") }
        rejects("concurrent restore planning is blocked") { _ = try concurrent.planRestore([]) }
        concurrent.reload()
        try await restoring.value
        check(concurrent.items.count == 1 && concurrent.items[0].terms.count == 5000 && concurrent.error == nil, "restore completes after rejected concurrent edit and reload")
        rejects("existing canonical-equivalent source duplicate rule retained") {
            try GlossaryStore.validate([Glossary(name: "Unicode", terms: [GlossaryTerm(source: "café", target: "一"), GlossaryTerm(source: "cafe\u{301}", target: "二")])])
        }
        print("ALL \(checks) RESTORE CHECKS PASSED")
    }
}
