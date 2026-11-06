import Foundation

/// One worker/model shared by desktop and browser requests. FIFO; cancellation
/// removes only its own waiter or interrupts only its own active request.
@MainActor final class TranslationQueue {
    private var active: UUID?
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    let engine: InferenceEngine
    init(engine: InferenceEngine) { self.engine = engine }
    func run(text: String, source: String?, target: String, style: String?, modelURL: URL, useGPU: Bool, onStart: @escaping () -> Void = {}) async throws -> String {
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
            return try await engine.translate(text: text, source: source, target: target, style: style, modelURL: modelURL, useGPU: useGPU)
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
