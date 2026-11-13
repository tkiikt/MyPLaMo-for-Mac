import Foundation
import CryptoKit
import Darwin
import zlib

/// The shared Windows/Mac v1 file format. Call file and compression work off the main actor.
enum GlossaryBackup {
    static let maximumBytes = 128 * 1024 * 1024
    private static let magic = Data("MyPLaMoGlossary\n".utf8)
    private static let chunkSize = 64 * 1024

    private struct Document: Codable {
        let Version: Int
        let Glossaries: [Book]
    }
    private struct Book: Codable {
        let Id: String
        let Name: String
        let Terms: [Term]
    }
    private struct Term: Codable {
        let Source: String
        let Target: String
        let From: String
        let To: String
    }

    static func read(from url: URL) throws -> [Glossary] {
        // Bound reads as well as checking the initial size: a file may grow after opening.
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw invalid("通常のバックアップファイルを選択してください。") }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw tooLarge() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        while true {
            let chunk = try handle.read(upToCount: min(chunkSize, maximumBytes - bytes.count + 1)) ?? Data()
            if chunk.isEmpty { break }
            guard bytes.count + chunk.count <= maximumBytes else { throw tooLarge() }
            bytes.append(chunk)
        }
        return try decode(bytes)
    }

    static func encode(_ items: [Glossary]) throws -> Data {
        try GlossaryStore.validate(items)
        let document = Document(Version: 1, Glossaries: items.map { book in
            Book(Id: book.id, Name: book.name, Terms: book.terms.map {
                Term(Source: $0.source, Target: $0.target, From: $0.from, To: $0.to)
            })
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(document)
        guard payload.count <= maximumBytes else { throw tooLarge() }
        var result = magic
        result.append(contentsOf: SHA256.hash(data: payload))
        result.append(try gzip(payload, compress: true, limit: maximumBytes - 48))
        return result
    }

    static func decode(_ data: Data) throws -> [Glossary] {
        guard data.count <= maximumBytes else { throw tooLarge() }
        guard data.count > 48, data.prefix(16) == magic else {
            throw invalid("用語集バックアップの形式ではないか、ファイルが途中で切れています。")
        }
        let payload = try gzip(Data(data.dropFirst(48)), compress: false, limit: maximumBytes)
        guard Data(SHA256.hash(data: payload)) == data.subdata(in: 16..<48) else {
            throw invalid("バックアップの整合性を確認できません（SHA-256不一致）。ファイルが破損している可能性があります。")
        }
        guard String(data: payload, encoding: .utf8) != nil else { throw invalid("バックアップのJSONがUTF-8ではありません。") }
        let document: Document
        do {
            // JSONDecoder accepts 1.0 as Int; the common format requires an integer token.
            guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let version = root["Version"] as? NSNumber,
                  ["i", "q", "s", "l", "I", "Q", "S", "L"].contains(String(cString: version.objCType)) else {
                throw invalid("バックアップのVersionは整数で指定する必要があります。")
            }
            guard version == NSNumber(value: 1) else {
                throw invalid("このバックアップのバージョンには対応していません。MyPLaMoを更新してからお試しください。")
            }
            document = try JSONDecoder().decode(Document.self, from: payload)
        } catch let error as GlossaryFailure { throw error }
        catch { throw invalid("バックアップのJSONまたはデータの型が不正です。\n\(error.localizedDescription)") }
        let items = document.Glossaries.map { book in
            Glossary(id: book.Id, name: book.Name, terms: book.Terms.map {
                // The interchange format has no term ID. Internal identity is newly allocated.
                GlossaryTerm(source: $0.Source, target: $0.Target, from: $0.From, to: $0.To)
            })
        }
        try GlossaryStore.validate(items)
        return items
    }

    static func write(_ items: [Glossary], to url: URL) throws {
        let data = try encode(items)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".myplamo-backup-\(UUID().uuidString).tmp")
        // Exclusive creation prevents an unrelated file from being overwritten at the temporary path.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw fileError("バックアップの一時ファイルを作成できません。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        // Same-directory POSIX rename atomically replaces an existing file. A failure leaves it intact.
        guard rename(temporary.path, url.path) == 0 else { throw fileError("バックアップを保存・置換できません。元のファイルは保持されています。") }
    }

    private static func gzip(_ input: Data, compress: Bool, limit: Int) throws -> Data {
        var stream = z_stream()
        // 15 + 16 selects the gzip wrapper specifically, rather than zlib/raw DEFLATE.
        let initialized = compress
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw invalid("GZip処理を初期化できません。") }
        defer { if compress { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        return try input.withUnsafeBytes { bytes -> Data in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while true {
                // At the limit, allow one byte of output to detect overflow and stop immediately.
                let capacity = min(chunkSize, limit - output.count + 1)
                let status: Int32 = buffer.withUnsafeMutableBytes { chunk in
                    stream.next_out = chunk.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    return compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                }
                let produced = capacity - Int(stream.avail_out)
                guard output.count + produced <= limit else { throw tooLarge() }
                output.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw invalid("GZipデータの後ろに余分なデータがあります。") }
                    return output
                }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else {
                    throw invalid(compress ? "バックアップをGZip形式に圧縮できません。" : "バックアップのGZipデータが破損しているか、途中で切れています。")
                }
            }
        }
    }

    private static func invalid(_ message: String) -> GlossaryFailure { .invalid(message) }
    private static func tooLarge() -> GlossaryFailure { invalid("バックアップファイルと展開後のJSONは、それぞれ128MiB以下にしてください。") }
    private static func fileError(_ message: String) -> GlossaryFailure { invalid("\(message)\n\(String(cString: strerror(errno)))") }
}
