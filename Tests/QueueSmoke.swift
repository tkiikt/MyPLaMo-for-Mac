import Foundation
import Combine

// This test double replaces only the process-backed engine. The queue, pipeline,
// segmenter, parser, prompt validation and glossary types are production sources.
@MainActor final class InferenceEngine: ObservableObject {
    struct Call { let text: String; let context: String; let history: [TranslationPair] }
    @Published var output = ""
    private(set) var calls: [Call] = []
    private(set) var cancelCount = 0
    private var continuation: CheckedContinuation<String, Error>?
    func translate(text: String, source: String?, target: String, style: String?, modelURL: URL, useGPU: Bool, context: String, glossary: [GlossaryTerm], history: [TranslationPair]) async throws -> String {
        guard continuation == nil else { throw TranslationError.invalidInput("Concurrent engine calls") }
        calls.append(Call(text: text, context: context, history: history))
        output = ""
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete(_ text: String) {
        guard let pending = continuation else { fatalError("No pending inference") }
        continuation = nil; output = text; pending.resume(returning: text)
    }
    func cancel() {
        cancelCount += 1
        let pending = continuation; continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

@main struct QueueSmoke {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw TranslationError.invalidInput("Timed out awaiting queue state") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func main() async throws {
        let engine = InferenceEngine(), url = URL(fileURLWithPath: "/unused-model")
        let queue = TranslationQueue(engine: engine)
        var starts: [String] = []
        func run(_ name: String, text: String? = nil, context: String = "", contextual: Bool = true, format: DocumentFormat = .text, partial: @escaping (String) -> Void = { _ in }) async throws -> String {
            try await queue.run(text: text ?? name, source: "en", target: "ja", style: "polite", modelURL: url, useGPU: true, context: context, useContext: contextual, format: format, onPartial: partial, onStart: { starts.append(name) })
        }
        let first = Task { try await run("first") }
        try await until { engine.calls.count == 1 }
        let cancelled = Task { try await run("cancelled") }
        await Task.yield()
        let third = Task { try await run("third") }
        await Task.yield()
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled waiter completed") } catch is CancellationError {}
        assert(engine.cancelCount == 0 && starts == ["first"])
        engine.complete("一番")
        let firstResult = try await first.value
        assert(firstResult == "一番")
        try await until { engine.calls.count == 2 }
        assert(starts == ["first", "third"])
        engine.complete("三番")
        let thirdResult = try await third.value
        assert(thirdResult == "三番")
        print("PASS FIFO and cancelled waiter isolation")

        let active = Task { try await run("active") }
        try await until { engine.calls.count == 3 }
        let successor = Task { try await run("successor") }
        await Task.yield(); active.cancel()
        do { _ = try await active.value; fatalError("Cancelled active request completed") } catch is CancellationError {}
        try await until { engine.calls.count == 4 }
        assert(engine.cancelCount == 1 && engine.calls.last?.text == "successor")
        engine.complete("次")
        let successorResult = try await successor.value
        assert(successorResult == "次")
        print("PASS active cancellation hands gate to next request")

        var documentPartials: [String] = []
        let document = Task { try await run("document", text: "{\"first\":\"Hello world\",\"second\":\"Good morning\"}", context: "Manual", format: .json, partial: { documentPartials.append($0) }) }
        try await until { engine.calls.count == 5 }
        let later = Task { try await run("later", context: "Next request") }
        await Task.yield()
        assert(engine.calls.last!.history.isEmpty)
        engine.complete("こんにちは")
        try await until { engine.calls.count == 6 }
        assert(engine.calls.last!.text == "Good morning")
        assert(engine.calls.last!.history == [TranslationPair(source: "Hello world", target: "こんにちは")])
        assert(engine.calls.last!.context.contains("Manual"))
        assert(!starts.contains("later"))
        engine.complete("おはよう")
        let result = try await document.value
        assert(result == "{\"first\":\"こんにちは\",\"second\":\"おはよう\"}")
        assert(documentPartials.isEmpty)
        try await until { engine.calls.count == 7 }
        assert(engine.calls.last!.history.isEmpty && engine.calls.last!.context == "Next request")
        engine.complete("後")
        _ = try await later.value
        print("PASS document spans serialized, structure retained and request history reset")

        var partials: [String] = []
        let noContext = Task { try await run("context-off", text: "One sentence\r\n\r\nSecond sentence", context: "Must not be forwarded", contextual: false, partial: { partials.append($0) }) }
        try await until { engine.calls.count == 8 }
        assert(engine.calls.last!.context.isEmpty && engine.calls.last!.history.isEmpty)
        engine.complete("一文")
        try await until { engine.calls.count == 9 }
        assert(engine.calls.last!.context.isEmpty && engine.calls.last!.history.isEmpty)
        engine.complete("二文")
        let plain = try await noContext.value
        assert(plain == "一文\r\n\r\n二文")
        assert(partials.last == plain)
        assert(!documentPartials.contains(plain))
        print("PASS context off, CRLF preservation and request-local streaming")
        let callCount = engine.calls.count, started = Date()
        let oversizedGrapheme = "a" + String(repeating: "\u{301}", count: 1500)
        do {
            _ = try await run("oversized-grapheme", text: oversizedGrapheme)
            fatalError("Oversized grapheme should be rejected")
        } catch is CancellationError { fatalError("Unexpected cancellation") }
        catch { assert(engine.calls.count == callCount && Date().timeIntervalSince(started) < 5) }
        let recovery = Task { try await run("after-invalid") }
        try await until { engine.calls.count == callCount + 1 }
        engine.complete("復帰")
        _ = try await recovery.value
        print("PASS oversized grapheme rejected before inference; queue recovers")
    }
}
