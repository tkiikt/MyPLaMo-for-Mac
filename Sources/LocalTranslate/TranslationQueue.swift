import Foundation
import Combine

/// One worker/model shared by desktop and browser requests. FIFO; cancellation
/// removes only its own waiter or interrupts only its own active request.
@MainActor final class TranslationQueue {
    private var active: UUID?
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    let engine: InferenceEngine
    init(engine: InferenceEngine) { self.engine = engine }
    func run(text: String, source: String?, target: String, style: String? = nil, modelURL: URL, useGPU: Bool, context: String = "", glossary: [GlossaryTerm] = [], useContext: Bool = false, format: DocumentFormat = .text, onProgress: @escaping (Int, Int) -> Void = { _, _ in }, onPartial: @escaping (String) -> Void = { _ in }, onStart: @escaping () -> Void = {}) async throws -> String {
        try PromptBuilder.validateOptions(source: source, target: target, style: style)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if active == nil { active = id; continuation.resume() }
                else { waiting.append((id, continuation)) }
            }
            defer { release(id) }
            try Task.checkCancellation()
            onStart()
            return try await TranslationPipeline.run(text: text, format: format, context: context, useContext: useContext, onProgress: onProgress, onPartial: onPartial) { core, reference, history, output in
                let subscription = self.engine.$output.dropFirst().sink(receiveValue: output)
                defer { subscription.cancel() }
                return try await self.engine.translate(text: core, source: source, target: target, style: style, modelURL: modelURL, useGPU: useGPU, context: reference, glossary: glossary, history: history)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } }
    }
    private func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        if !waiting.isEmpty {
            let next = waiting.removeFirst(); active = next.0; next.1.resume()
        }
    }
    private func cancel(_ id: UUID) {
        if let i = waiting.firstIndex(where: { $0.0 == id }) { waiting.remove(at: i).1.resume(throwing: CancellationError()) }
        if active == id { engine.cancel() }
    }
}
