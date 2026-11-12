import Foundation

/// Unicode-safe chunks retain line breaks and whitespace outside the model.
enum TranslationSegments {
    static func split(_ text: String, limit: Int = 1400) throws -> [String] {
        var result: [String] = []
        let expression = try! NSRegularExpression(pattern: "[^\\r\\n]+|\\r\\n|[\\r\\n]")
        let ns = text as NSString
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var remaining = ns.substring(with: match.range)
            while remaining.utf16.count > limit {
                let prefix = PromptBuilder.prefixUTF16(remaining, limit: limit)
                guard !prefix.isEmpty else { throw TranslationError.invalidInput("1文字に結合する記号が多すぎます。原文を短くしてください。") }
                var end = prefix.endIndex
                if let boundary = prefix.lastIndex(where: { " 。.!?！？".contains($0) }), prefix[..<boundary].utf16.count >= limit / 2 {
                    end = prefix.index(after: boundary)
                }
                let chunk = String(prefix[..<end]); result.append(chunk)
                remaining.removeFirst(chunk.count)
            }
            if !remaining.isEmpty { result.append(remaining) }
        }
        return result
    }
    static func hasText(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.rangeOfCharacter(from: .letters) != nil && text.range(of: #"^(?:[a-z][a-z0-9+.-]*://|/|\$\{|[A-Z]:\\|\S+@\S+\.\S+)"#, options: [.regularExpression, .caseInsensitive]) == nil
    }
    static func whitespace(_ value: String) -> (leading: String, core: String, trailing: String) {
        let leading = String(value.prefix(while: { $0.isWhitespace }))
        let trailing = String(value.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let core = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (leading, core, core.isEmpty ? "" : trailing)
    }
}
