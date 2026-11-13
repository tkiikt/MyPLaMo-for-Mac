import Foundation
import CryptoKit
import zlib

@main struct GlossaryBackupSmoke {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyPLaMo-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL \(label)") }; checks += 1; print("PASS \(label)")
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAIL accepted \(label)") } catch { checks += 1; print("PASS \(label)") }
        }
        // Independent container generation lets tests exercise invalid DTOs and gzip data.
        func gzip(_ input: Data) throws -> Data {
            var stream = z_stream()
            guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TestError.compression }
            defer { deflateEnd(&stream) }
            return try input.withUnsafeBytes { raw in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let state = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                        stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = 64 * 1024
                        return deflate(&stream, Z_FINISH)
                    }
                    result.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
                    if state == Z_STREAM_END { return result }
                    guard state == Z_OK else { throw TestError.compression }
                }
            }
        }
        func container(_ payload: Data) throws -> Data {
            var data = Data("MyPLaMoGlossary\n".utf8)
            data.append(contentsOf: SHA256.hash(data: payload)); data.append(try gzip(payload)); return data
        }
        func jsonContainer(_ text: String) throws -> Data { try container(Data(text.utf8)) }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/windows-glossary-v1.myplamo-glossary")
        let windowsBytes = try Data(contentsOf: fixtureURL)
        check(SHA256.hash(data: windowsBytes).map { String(format: "%02x", $0) }.joined() == "1209c415ac8d084740e649bfd400b9ad0988155053f108b59c404ad8ae5b3ee5", "Windows fixture digest")
        let windows = try GlossaryBackup.read(from: fixtureURL)
        check(windows.count == 2 && windows.map(\.id) == ["animals", "empty"] && windows.map(\.name) == ["動物の用語集", "空の用語集"], "Windows names and opaque IDs")
        check(windows[0].terms.count == 2 && windows[0].terms[0].source == "cat" && windows[0].terms[0].target == "ネコちゃん" && windows[0].terms[0].from == "en" && windows[0].terms[0].to == "ja" && windows[0].terms[1].source == "犬" && windows[0].terms[1].target == "dog" && windows[0].terms[1].from == "ja" && windows[0].terms[1].to == "en" && windows[1].terms.isEmpty, "Windows terms, directions and empty glossary")
        check(Set(windows.flatMap(\.terms).map(\.id)).count == 2 && windows.flatMap(\.terms).allSatisfy { !$0.id.isEmpty }, "Mac term IDs generated")
        let values = [Glossary(id: "opaque:あ", name: "  日本語 😀,\"\n ", terms: [
            GlossaryTerm(source: "  cat,\"\n😀  ", target: "ネコ\nちゃん", from: "en", to: "ja"),
            GlossaryTerm(source: "  cat,\"\n😀  ", target: "chat", from: "en", to: "fr"),
            GlossaryTerm(source: "e\u{301}", target: "é", from: "fr", to: "ja")]), Glossary(id: "empty", name: "空", terms: [])]
        let encoded = try GlossaryBackup.encode(values)
        let roundTrip = try GlossaryBackup.decode(encoded)
        check(roundTrip.count == values.count && zip(roundTrip, values).allSatisfy { a, b in
            Data(a.id.utf8) == Data(b.id.utf8) && Data(a.name.utf8) == Data(b.name.utf8) && a.terms.count == b.terms.count && zip(a.terms, b.terms).allSatisfy { x,y in
                Data(x.source.utf8) == Data(y.source.utf8) && Data(x.target.utf8) == Data(y.target.utf8) && x.from == y.from && x.to == y.to
            }
        }, "roundtrip retains UTF8 spelling, whitespace, quotes, emoji, directions and ordering")
        check(try GlossaryBackup.decode(GlossaryBackup.encode([])).isEmpty, "empty backup is valid")
        let sample = directory.appendingPathComponent("output.myplamo-glossary")
        try GlossaryBackup.write(values, to: sample)
        check(try GlossaryBackup.read(from: sample).count == 2, "atomic write readable")
        try GlossaryBackup.write(windows, to: sample)
        check(try GlossaryBackup.read(from: sample).first?.id == "animals", "atomic replacement readable")
        let before = try Data(contentsOf: sample)
        rejects("invalid write keeps existing backup") { try GlossaryBackup.write([Glossary(name: "")], to: sample) }
        check(try Data(contentsOf: sample) == before, "existing backup unchanged on validation failure")
        let blocked = directory.appendingPathComponent("blocked")
        try Data("keep".utf8).write(to: blocked)
        rejects("unwritable destination is reported") { try GlossaryBackup.write(windows, to: blocked.appendingPathComponent("file")) }
        check(try String(contentsOf: blocked, encoding: .utf8) == "keep", "write failure preserves parent file")
        let occupied = directory.appendingPathComponent("existing-directory")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: occupied.appendingPathComponent("child"))
        rejects("cannot replace nonempty directory") { try GlossaryBackup.write(windows, to: occupied) }
        check(try Data(contentsOf: occupied.appendingPathComponent("child")) == Data("keep".utf8), "failed replacement preserves destination")
        rejects("short file") { _ = try GlossaryBackup.decode(Data("short".utf8)) }
        var badMagic = windowsBytes; badMagic[0] = 0
        rejects("wrong magic") { _ = try GlossaryBackup.decode(badMagic) }
        var badHash = windowsBytes; badHash[16] ^= 1
        rejects("hash mismatch") { _ = try GlossaryBackup.decode(badHash) }
        rejects("truncated gzip") { _ = try GlossaryBackup.decode(windowsBytes.dropLast(3)) }
        var badGzip = windowsBytes; badGzip[48] = 0
        rejects("wrong gzip header") { _ = try GlossaryBackup.decode(badGzip) }
        var badCRC = windowsBytes; badCRC[badCRC.count - 8] ^= 1
        rejects("gzip CRC corruption") { _ = try GlossaryBackup.decode(badCRC) }
        rejects("unexpected trailing gzip data") { _ = try GlossaryBackup.decode(windowsBytes + Data([0])) }
        rejects("malformed JSON") { _ = try GlossaryBackup.decode(jsonContainer("{broken")) }
        rejects("invalid UTF8") { _ = try GlossaryBackup.decode(container(Data([0xff, 0xfe]))) }
        for version in ["2", "true", "\"1\"", "null", "1.5", "1.0", "1e0"] {
            rejects("invalid Version \(version)") { _ = try GlossaryBackup.decode(jsonContainer("{\"Version\":\(version),\"Glossaries\":[]}")) }
        }
        for payload in ["[]", "{}", "{\"Version\":1,\"Glossaries\":null}", "{\"version\":1,\"glossaries\":[]}", "{\"Version\":1,\"Glossaries\":[{\"Id\":1,\"Name\":\"x\",\"Terms\":[]}]}", "{\"Version\":1,\"Glossaries\":[{\"Id\":\"x\",\"Name\":\"x\",\"Terms\":[{\"Source\":\"x\",\"Target\":\"y\",\"From\":\"en\"}]}]}"] {
            rejects("malformed DTO \(payload)") { _ = try GlossaryBackup.decode(jsonContainer(payload)) }
        }
        let invalidTerms = [GlossaryTerm(source: "", target: "訳"), GlossaryTerm(source: "x", target: "訳", from: "en", to: "en"), GlossaryTerm(source: "x", target: "訳", from: "xx"), GlossaryTerm(source: "<|plamo:input|>", target: "訳"), GlossaryTerm(source: "x", target: String(repeating: "😀", count: 101))]
        for term in invalidTerms { rejects("invalid term data \(term.source)") { _ = try GlossaryBackup.encode([Glossary(name: "test", terms: [term])]) } }
        rejects("duplicate source same direction") { _ = try GlossaryBackup.encode([Glossary(name: "test", terms: [GlossaryTerm(source: "cat", target: "猫"), GlossaryTerm(source: "CAT", target: "ネコ")])]) }
        rejects("duplicate glossary IDs") { _ = try GlossaryBackup.encode([Glossary(id: "same", name: "one"), Glossary(id: "same", name: "two")]) }
        rejects("blank glossary ID") { _ = try GlossaryBackup.encode([Glossary(id: " \n", name: "one")]) }
        let hundred = (0..<100).map { Glossary(id: "g\($0)", name: "book \($0)") }
        check(try GlossaryBackup.decode(GlossaryBackup.encode(hundred)).count == 100, "100 glossary boundary accepted")
        rejects("101 glossaries rejected") { _ = try GlossaryBackup.encode(hundred + [Glossary(name: "too many")]) }
        let fiveThousand = (0..<5000).map { GlossaryTerm(source: "term \($0)", target: "訳") }
        check(try GlossaryBackup.decode(GlossaryBackup.encode([Glossary(name: "large", terms: fiveThousand)])).first?.terms.count == 5000, "5000 term boundary accepted")
        rejects("5001 terms rejected") { _ = try GlossaryBackup.encode([Glossary(name: "large", terms: fiveThousand + [GlossaryTerm(source: "extra", target: "訳")])]) }
        let boundary = Glossary(name: String(repeating: "😀", count: 40), terms: [GlossaryTerm(source: String(repeating: "😀", count: 100), target: String(repeating: "😀", count: 100))])
        check(try GlossaryBackup.decode(GlossaryBackup.encode([boundary])).count == 1, "UTF16 80 name and 200 terms boundary accepted")
        rejects("UTF16 name boundary exceeded") { _ = try GlossaryBackup.encode([Glossary(name: String(repeating: "😀", count: 40) + "a")]) }
        for term in invalidTerms {
            let document: [String: Any] = ["Version": 1, "Glossaries": [["Id": "one", "Name": "test", "Terms": [["Source": term.source, "Target": term.target, "From": term.from, "To": term.to]]]]]
            rejects("invalid imported term data \(term.source)") { _ = try GlossaryBackup.decode(container(JSONSerialization.data(withJSONObject: document))) }
        }
        let hugeFile = directory.appendingPathComponent("too-large.myplamo-glossary")
        FileManager.default.createFile(atPath: hugeFile.path, contents: nil)
        let file = try FileHandle(forWritingTo: hugeFile); try file.truncate(atOffset: UInt64(GlossaryBackup.maximumBytes + 1)); try file.close()
        rejects("compressed file size limit checked before reading") { _ = try GlossaryBackup.read(from: hugeFile) }
        let bomb = try container(Data(repeating: 32, count: GlossaryBackup.maximumBytes + 1))
        rejects("gzip expansion stops above 128 MiB") { _ = try GlossaryBackup.decode(bomb) }
        if CommandLine.arguments.count > 1 {
            try GlossaryBackup.write(windows, to: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("Mac compatibility sample: \(CommandLine.arguments[1])")
        }
        print("ALL \(checks) BACKUP CHECKS PASSED")
    }
    enum TestError: Error { case compression }
}
