import Foundation

@main
struct InferenceSmoke {
    @MainActor
    static func main() async {
        let model = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Models/plamo-3-translate-0.8b-Q4_K_M.gguf")
        let engine = InferenceEngine()
        defer { engine.shutdown() }
        do {
            let start = Date()
            let english = try await engine.translate(text: "会議は来週の月曜日に変更されました。", source: "ja", target: "en", modelURL: model, useGPU: true)
            guard english.lowercased().contains("monday") else { throw TranslationError.server("GPU Japanese to English did not mention Monday") }
            print("PASS GPU ja→en (\(String(format: "%.2f", Date().timeIntervalSince(start))) s): \(english)")
            let japanese = try await engine.translate(text: "Please open the project dashboard.", source: "en", target: "ja", style: "polite", modelURL: model, useGPU: true)
            guard japanese.contains("ください") else { throw TranslationError.server("GPU English to Japanese did not produce polite Japanese") }
            print("PASS GPU en→ja: \(japanese)")
            let cpu = try await engine.translate(text: "This system is convenient.", source: "en", target: "ja", style: "plain", modelURL: model, useGPU: false)
            guard cpu.contains("便利") else { throw TranslationError.server("CPU English to Japanese did not produce expected meaning") }
            print("PASS CPU en→ja: \(cpu)")
            let pending = Task { @MainActor in
                try await engine.translate(text: String(repeating: "The project dashboard shows all active tasks. ", count: 60), source: "en", target: "ja", modelURL: model, useGPU: true)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            engine.cancel()
            do {
                _ = try await pending.value
                throw TranslationError.server("Cancelled translation unexpectedly completed")
            } catch is CancellationError {
                print("PASS cancellation")
            } catch let error as URLError where error.code == .cancelled {
                print("PASS cancellation")
            }
            guard !engine.isBusy else { throw TranslationError.server("Engine stayed busy after cancellation") }
            let recovered = try await engine.translate(text: "Good morning.", source: "en", target: "ja", modelURL: model, useGPU: true)
            guard recovered.contains("おはよう") else { throw TranslationError.server("Translation after cancellation did not recover") }
            print("PASS recovery after cancellation: \(recovered)")
            let generating = Task { @MainActor in
                try await engine.translate(text: String(repeating: "The project dashboard shows all active tasks. ", count: 100), source: "en", target: "ja", modelURL: model, useGPU: true)
            }
            let deadline = Date().addingTimeInterval(15)
            while engine.output.isEmpty || !engine.isBusy {
                if Date() > deadline { throw TranslationError.server("Generation did not start within 15 seconds") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            engine.cancel()
            do {
                _ = try await generating.value
                throw TranslationError.server("Streaming cancellation unexpectedly completed")
            } catch is CancellationError {
                print("PASS cancellation during streaming")
            } catch let error as URLError where error.code == .cancelled {
                print("PASS cancellation during streaming")
            }
            let again = try await engine.translate(text: "Thank you.", source: "en", target: "ja", modelURL: model, useGPU: true)
            guard again.contains("ありがとう") else { throw TranslationError.server("Streaming cancellation did not recover") }
            print("PASS recovery after streaming cancellation: \(again)")
            print("ALL INFERENCE SMOKE TESTS PASSED")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
