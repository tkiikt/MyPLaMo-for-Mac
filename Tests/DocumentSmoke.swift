import Foundation

@main struct DocumentSmoke {
    static func main() async throws {
        let json = "{\r\n  \"日本😀\": \"Hello\", \"n\": 42, \"url\": \"https://example.test\"\r\n}"
        let plan = try await DocumentTranslation.plan(text: json, format: .json)
        precondition(plan.format == .json && plan.spans.count == 1)
        let result = try await DocumentTranslation.render(plan: plan, translations: ["こんにちは😀"])
        precondition(result == json.replacingOccurrences(of: "Hello", with: "こんにちは😀"))
        print("PASS Swift/Python document plan and UTF-16 ranges")
        do {
            _ = try await DocumentTranslation.plan(text: "{bad", format: .json)
            fatalError("Invalid JSON accepted")
        } catch { print("PASS Swift parser error propagation") }
        let operation = Task { try await DocumentTranslation.plan(text: String(repeating: "Hello\n", count: 10000), format: .markdown) }
        operation.cancel()
        do { _ = try await operation.value; fatalError("Cancelled parser accepted") }
        catch is CancellationError { print("PASS Swift parser cancellation") }
    }
}
