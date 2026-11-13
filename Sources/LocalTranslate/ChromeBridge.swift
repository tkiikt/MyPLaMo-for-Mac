import Foundation
import Network
import CryptoKit
import Combine
import CoreFoundation

/// A validated browser request. UI preferences are deliberately not consulted here.
struct ChromeTranslationRequest {
    let text: String
    let source: String?
    let target: String
    let style: String?
    let glossaryID: String?
    let context: String

    init(json: [String: Any]) throws {
        func field(_ name: String, default fallback: String = "") throws -> String {
            guard let value = json[name] else { return fallback }
            guard let text = value as? String else { throw ChromeRequestError.message("\(name)の形式を確認してください。") }
            return text
        }
        text = try field("text")
        let from = try field("from")
        source = from.isEmpty ? nil : from
        target = try field("to", default: "ja")
        let form = try field("style", default: "polite")
        style = form.isEmpty ? nil : form
        let glossary = try field("glossaryId")
        glossaryID = glossary.isEmpty ? nil : glossary
        context = try field("context")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 2000 else {
            throw ChromeRequestError.message("文章を短くしてください（最大2,000文字）。")
        }
        guard context.utf16.count <= 1200 else { throw ChromeRequestError.message("参照する文脈が長すぎます（最大1,200文字）。") }
        guard PromptBuilder.languageCodes.contains(target), source == nil || PromptBuilder.languageCodes.contains(source!) else {
            throw ChromeRequestError.message("対応していない言語が選択されています。")
        }
        guard source != target else { throw ChromeRequestError.message("翻訳元と翻訳先は異なる言語を選んでください。") }
        guard style == nil || ["plain", "polite"].contains(style!) else { throw ChromeRequestError.message("文体の指定を確認してください。") }
        guard ![text, context, glossary].contains(where: { $0.contains("<|plamo:") }) else {
            throw ChromeRequestError.message("入力にモデルの制御記号が含まれています。")
        }
    }
}

private enum ChromeRequestError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Wire-compatible with the Windows MyPLaMo Chrome bridge.
/// The listener deliberately binds IPv4 loopback, never all interfaces.
@MainActor final class ChromeBridge: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Chrome連携はオフです"
    @Published private(set) var error: String?
    private var listener: NWListener?
    private var clients: [UUID: ChromeBridgeClient] = [:]
    private var generation = UUID()
    static let origin = "chrome-extension://oefekpcnnmijlldkpeplijencgdnakbb"

    func start(metadata: @escaping () throws -> [String: Any], translate: @escaping (ChromeTranslationRequest) async throws -> String) {
        guard listener == nil else { return }
        error = nil; status = "Chrome連携を開始中…"
        let token = UUID(); generation = token
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 47832)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    switch state {
                    case .ready: self.isRunning = true; self.status = "Chromeからの翻訳を受付中"
                    case .failed(let failure):
                        self.stop()
                        self.error = "Chrome連携を開始できません。別のMyPLaMoが起動していないか確認してください。\n\(failure.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == token, self.clients.count < 8 else { connection.cancel(); return }
                    let id = UUID()
                    let client = ChromeBridgeClient(connection: connection, metadata: metadata, translate: translate) { [weak self] in self?.clients[id] = nil }
                    self.clients[id] = client; client.start()
                }
            }
            listener.start(queue: .main)
        } catch { self.error = error.localizedDescription; status = "Chrome連携を開始できません" }
    }

    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil
        let current = clients.values; clients.removeAll()
        for client in current { client.stop() }
        isRunning = false; status = "Chrome連携はオフです"
    }
}

/// Only the bounded subset needed by a browser WebSocket is implemented:
/// masked text/continuation, ping/pong, and close. HTTP is never exposed as an API.
@MainActor private final class ChromeBridgeClient {
    let connection: NWConnection
    let translate: (ChromeTranslationRequest) async throws -> String
    let metadata: () throws -> [String: Any]
    let onClose: () -> Void
    var buffer = Data()
    var fragmented = Data()
    var fragmentOpen = false
    var upgraded = false
    var requested = false
    var stopped = false
    var closing = false
    var work: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    var heartbeat: Task<Void, Never>?

    init(connection: NWConnection, metadata: @escaping () throws -> [String: Any], translate: @escaping (ChromeTranslationRequest) async throws -> String, onClose: @escaping () -> Void) {
        self.connection = connection; self.metadata = metadata; self.translate = translate; self.onClose = onClose
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.stop() }
                if case .cancelled = state { self?.stop() }
            }
        }
        connection.start(queue: .main)
        setTimeout(seconds: 10)
        receive()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; work?.cancel(); timeout?.cancel(); heartbeat?.cancel()
        work = nil; timeout = nil; heartbeat = nil
        connection.cancel(); onClose()
    }
    func setTimeout(seconds: UInt64) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            self?.stop()
        }
    }
    func receive() {
        guard !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, failure in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if let data { self.buffer.append(data) }
                if self.buffer.count > 65_536 { self.stop(); return }
                self.consume()
                if complete || failure != nil { self.stop() } else { self.receive() }
            }
        }
    }
    func consume() {
        if !upgraded {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 8192 { rejectHTTP(431) }; return
            }
            guard end.upperBound <= 8192, let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { rejectHTTP(400); return }
            let lines = header.components(separatedBy: "\r\n")
            guard lines.first == "GET /translate HTTP/1.1" else { rejectHTTP(404); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { rejectHTTP(400); return }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { rejectHTTP(400); return }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["origin"] == ChromeBridge.origin,
                  headers["host"] == "127.0.0.1:47832",
                  headers["upgrade"]?.lowercased() == "websocket",
                  headers["connection"]?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true,
                  headers["sec-websocket-version"] == "13",
                  let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16,
                  headers["content-length"] == nil, headers["transfer-encoding"] == nil else { rejectHTTP(403); return }
            let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            let accept = Data(digest).base64EncodedString()
            buffer.removeSubrange(..<end.upperBound)
            buffer = Data(buffer)
            upgraded = true
            sendRaw(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
        }
        while !stopped, !closing, buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(14))
            let fin = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0f
            guard bytes[0] & 0x70 == 0, bytes[1] & 0x80 != 0 else { close(code: 1002); return }
            var length = Int(bytes[1] & 0x7f), cursor = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) * 256 + Int(bytes[3]); cursor = 4
                guard length >= 126 else { close(code: 1002); return }
            } else if length == 127 { close(code: 1009); return }
            guard length <= 32768, length + fragmented.count <= 32768 else { close(code: 1009); return }
            guard opcode < 8 || (fin && length <= 125) else { close(code: 1002); return }
            guard buffer.count >= cursor + 4 + length else { return }
            let mask = [UInt8](buffer[cursor..<(cursor + 4)])
            let payload = Data(buffer[(cursor + 4)..<(cursor + 4 + length)].enumerated().map { $0.element ^ mask[$0.offset % 4] })
            buffer.removeFirst(cursor + 4 + length)
            // Normalize Data's startIndex after removeFirst before indexed parsing.
            buffer = Data(buffer)
            switch opcode {
            case 8: close(code: 1000); return
            case 9: sendFrame(payload, opcode: 10)
            case 10: break
            case 1:
                guard !requested, !fragmentOpen else { close(code: 1008); return }
                if fin { handle(payload) } else { fragmentOpen = true; fragmented = payload }
            case 0:
                guard !requested, fragmentOpen else { close(code: 1002); return }
                fragmented.append(payload)
                if fin { let full = fragmented; fragmented = Data(); fragmentOpen = false; handle(full) }
            default: close(code: 1003); return
            }
        }
    }
    func handle(_ data: Data) {
        requested = true
        let translationRequest: ChromeTranslationRequest
        do {
            guard String(data: data, encoding: .utf8) != nil,
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ChromeRequestError.message("正しいJSONオブジェクトを送信してください。")
            }
            if let value = request["protocolVersion"] {
                guard let version = value as? NSNumber,
                      CFGetTypeID(version) != CFBooleanGetTypeID(),
                      !["d", "f"].contains(String(cString: version.objCType)), version.intValue == 1 else {
                    throw ChromeRequestError.message("本体と拡張機能の通信バージョンが対応していません。両方を更新してください。")
                }
            }
            if let action = request["action"] {
                guard let name = action as? String, name == "metadata" else {
                    throw ChromeRequestError.message("対応していない操作です。")
                }
                sendJSON(try metadata(), final: true)
                return
            }
            translationRequest = try ChromeTranslationRequest(json: request)
        } catch {
            sendJSON(["error": error.localizedDescription], final: true)
            return
        }
        setTimeout(seconds: 480)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, !self.stopped else { return }
                self.sendJSON(["working": true])
            }
        }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.translate(translationRequest)
                try Task.checkCancellation()
                self.sendJSON(["translation": result], final: true)
            } catch {
                if !Task.isCancelled { self.sendJSON(["error": error.localizedDescription], final: true) }
            }
        }
    }
    func sendJSON(_ object: [String: Any], final: Bool = false) {
        var reply = object
        reply["server"] = ["platform": "macos", "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.0", "protocolVersion": 1, "capabilities": ["options", "glossaries", "context"]]
        guard !stopped, let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        if final { heartbeat?.cancel(); timeout?.cancel() }
        sendFrame(data, opcode: 1) { [weak self] in if final { self?.close(code: 1000) } }
    }
    func sendFrame(_ payload: Data, opcode: UInt8, completion: (() -> Void)? = nil) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count <= 65535 { frame.append(126); frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 255)) }
        else { stop(); return }
        frame.append(payload); sendRaw(frame, completion: completion)
    }
    func sendRaw(_ data: Data, completion: (() -> Void)? = nil) {
        guard !stopped else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] failure in
            Task { @MainActor in
                if failure != nil { self?.stop() } else { completion?() }
            }
        })
    }
    func close(code: UInt16) {
        guard !closing else { return }; closing = true
        sendFrame(Data([UInt8(code >> 8), UInt8(code & 255)]), opcode: 8) { [weak self] in self?.stop() }
        // Bound clients that stop reading during the close handshake.
        setTimeout(seconds: 2)
    }
    func rejectHTTP(_ code: Int) {
        guard !closing else { return }; closing = true
        sendRaw(Data("HTTP/1.1 \(code) Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) { [weak self] in self?.stop() }
        setTimeout(seconds: 2)
    }
}
