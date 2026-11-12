import Foundation

/// One document owns its temporary context. Never carries context across calls.
@MainActor enum TranslationPipeline {
    static func run(text: String, format: DocumentFormat, context: String, useContext: Bool,
                    onProgress: (Int, Int) -> Void = { _, _ in },
                    onPartial: @escaping (String) -> Void = { _ in },
                    translate: (String, String, [TranslationPair], @escaping (String) -> Void) async throws -> String) async throws -> String {
        try PromptBuilder.validateContent(text); try PromptBuilder.validateContent(context)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= PromptBuilder.maximumCharacters else {
            throw TranslationError.invalidInput("原文は1〜6,000文字で入力してください。")
        }
        let plan = try await DocumentTranslation.plan(text: text, format: format)
        let reference = useContext ? PromptBuilder.prefixUTF16([context, plan.format == .text ? "" : PromptBuilder.prefixUTF16(text, limit: 800)].filter { !$0.isEmpty }.joined(separator: "\n"), limit: 1200) : ""
        let segments = try plan.spans.map { try TranslationSegments.split($0.text) }
        let total = segments.flatMap { $0 }.filter(TranslationSegments.hasText).count
        var completed = 0, history: [TranslationPair] = [], translations: [String] = []
        onProgress(0, total)
        for parts in segments {
            var assembled = ""
            for part in parts {
                try Task.checkCancellation()
                guard TranslationSegments.hasText(part) else { assembled += part; continue }
                let whitespace = TranslationSegments.whitespace(part)
                let prefix = assembled + whitespace.leading
                let result = try await translate(whitespace.core, reference, useContext ? history : []) { partial in
                    if plan.format == .text { onPartial(prefix + partial) }
                }
                try Task.checkCancellation()
                assembled += whitespace.leading + result.trimmingCharacters(in: .whitespacesAndNewlines) + whitespace.trailing
                if useContext {
                    history.append(TranslationPair(source: whitespace.core, target: result))
                    while history.count > 2 || history.reduce(0, { $0 + $1.source.utf16.count + $1.target.utf16.count }) > 1600 { history.removeFirst() }
                }
                completed += 1; onProgress(completed, total)
                if plan.format == .text { onPartial(assembled) }
            }
            translations.append(assembled)
        }
        try Task.checkCancellation()
        return try await DocumentTranslation.render(plan: plan, translations: translations)
    }
}
