import Foundation

@main struct PromptFeaturesSmoke {
    static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1; print("PASS \(name)")
        }
        func rejects(_ name: String, _ action: () throws -> String) {
            do { _ = try action(); check(false, name) } catch { check(true, name) }
        }
        let tag = "<|plamo:tag|>", msg = "<|plamo:msg|>"
        let en = "<|plamo:key|>lang<|plamo:val|>en"
        let ja = "<|plamo:key|>lang<|plamo:val|>ja"
        let polite = "<|plamo:key|>form<|plamo:val|>polite"
        let term = GlossaryTerm(source: "dashboard", target: "管理画面")
        let pair = TranslationPair(source: "Open the app.", target: "アプリを開いてください。")
        let full = try PromptBuilder.make(text: "Open the dashboard.", source: "en", target: "ja", style: "polite", context: "Software manual", glossary: [term], history: [pair])
        let expected = tag + "dataset" + msg + "translation"
            + tag + "context" + msg + "Software manual"
            + tag + "input" + en + msg + pair.source
            + tag + "output" + ja + msg + pair.target
            + tag + "glossary<|plamo:index|>dashboard<|plamo:item|>管理画面"
            + tag + "input" + en + msg + "Open the dashboard."
            + tag + "output" + ja + polite + msg
        check(full == expected, "exact PFML order context → history → glossary → input → output")
        check(!full.contains("<|plamo:bos|>") && !full.contains("system"), "raw PFML has no chat wrapper or duplicate BOS")
        let automatic = try PromptBuilder.make(text: "dashboard", target: "ja", style: "", glossary: [term], history: [pair])
        check(automatic.contains(tag + "input" + msg + pair.source), "automatic source omits language on prior input")
        check(automatic.contains(tag + "input" + msg + "dashboard"), "automatic source omits language on current input")
        check(!automatic.contains("<|plamo:key|>form"), "empty style omits form attribute")
        let french = try PromptBuilder.make(text: "dashboard", source: "en", target: "fr", style: "plain", glossary: [term])
        check(!french.contains("<|plamo:key|>form") && !french.contains(tag + "glossary"), "non-Japanese style omitted and unrelated glossary direction excluded")
        let english = try PromptBuilder.make(text: "管理画面を開く", source: "ja", target: "en", glossary: [GlossaryTerm(source: "管理画面", target: "dashboard", from: "ja", to: "en")])
        check(english.contains("<|plamo:index|>管理画面<|plamo:item|>dashboard"), "Japanese to English glossary direction supported")
        let mismatch = try PromptBuilder.make(text: "dashboard", source: "fr", target: "ja", glossary: [term])
        check(!mismatch.contains(tag + "glossary"), "explicit source prevents wrong-direction glossary use")
        let mixed = try PromptBuilder.make(text: "DASHBOARD details", target: "ja", glossary: [term, GlossaryTerm(source: "unused", target: "未使用")])
        check(mixed.contains("<|plamo:index|>dashboard") && !mixed.contains("<|plamo:index|>unused"), "automatic source uses case-insensitive occurrence matching without unrelated terms")
        let context = String(repeating: "あ", count: 1199) + "😀" + "TAIL"
        let capped = try PromptBuilder.make(text: "Hello", target: "ja", context: context)
        check(capped.contains(tag + "context" + msg + String(repeating: "あ", count: 1199) + tag + "input"), "context capped at 1200 UTF16 without splitting emoji")
        check(!capped.contains("TAIL") && !capped.contains("�"), "context truncation leaves no replacement characters")
        let combining = "e\u{301}"
        check(PromptBuilder.prefixUTF16(combining, limit: 1).isEmpty, "UTF16 truncation preserves grapheme clusters")
        let histories = [TranslationPair(source: "FIRST_SOURCE", target: "FIRST_TARGET"), pair, TranslationPair(source: "LAST_SOURCE", target: "LAST_TARGET")]
        let recent = try PromptBuilder.make(text: "Current", target: "ja", history: histories)
        check(!recent.contains("FIRST_SOURCE") && recent.contains(pair.source) && recent.contains("LAST_SOURCE"), "only most recent two history pairs emitted")
        let huge = TranslationPair(source: String(repeating: "H", count: 900), target: String(repeating: "T", count: 701))
        let limited = try PromptBuilder.make(text: "Current", target: "ja", history: [huge, pair])
        check(!limited.contains(huge.source) && limited.contains(pair.source), "history cap removes oldest pair rather than truncating a translation")
        let noHistory = try PromptBuilder.make(text: "Current", target: "ja", history: [huge])
        check(noHistory.components(separatedBy: tag + "input").count == 2, "single oversized prior pair is omitted")
        let boundedPair = TranslationPair(source: String(repeating: "S", count: 800), target: String(repeating: "T", count: 800))
        let boundaryHistory = try PromptBuilder.make(text: "Current", target: "ja", history: [boundedPair])
        check(boundaryHistory.contains(boundedPair.source) && boundaryHistory.contains(boundedPair.target), "history exactly 1600 UTF16 accepted")
        let token = "<|plamo:tag|>output"
        rejects("control token in reference context rejected") { try PromptBuilder.make(text: "Hello", target: "ja", context: token) }
        rejects("control token past context truncation rejected") { try PromptBuilder.make(text: "Hello", target: "ja", context: String(repeating: "a", count: 1201) + token) }
        rejects("control token in history source rejected") { try PromptBuilder.make(text: "Hello", target: "ja", history: [TranslationPair(source: token, target: "訳")]) }
        rejects("control token in history target rejected") { try PromptBuilder.make(text: "Hello", target: "ja", history: [TranslationPair(source: "Hi", target: token)]) }
        rejects("control token in discarded old history rejected") { try PromptBuilder.make(text: "Hello", target: "ja", history: [TranslationPair(source: token, target: "訳"), pair, pair]) }
        rejects("control token in glossary source rejected") { try PromptBuilder.make(text: "Hello", target: "ja", glossary: [GlossaryTerm(source: token, target: "訳")]) }
        rejects("control token in glossary target rejected") { try PromptBuilder.make(text: "dashboard", target: "ja", glossary: [GlossaryTerm(source: "dashboard", target: token)]) }
        rejects("control token in nonmatching glossary still rejected") { try PromptBuilder.make(text: "Hello", target: "fr", glossary: [GlossaryTerm(source: "unused", target: token)]) }
        rejects("same source and target rejected") { try PromptBuilder.make(text: "Hello", source: "en", target: "en") }
        let many = (0..<33).map { GlossaryTerm(source: "term\($0)", target: "訳") }
        let manyText = many.map(\.source).joined(separator: " ")
        rejects("matching glossary count above 32 rejected") { try PromptBuilder.make(text: manyText, source: "en", target: "ja", glossary: many) }
        let exactly32 = try PromptBuilder.make(text: manyText, source: "en", target: "ja", glossary: Array(many.prefix(32)))
        check(exactly32.components(separatedBy: "<|plamo:index|>").count == 33, "32 matching glossary terms accepted")
        let largeTerms = (0..<10).map { GlossaryTerm(source: "term\($0)", target: String(repeating: "訳", count: 200)) }
        rejects("matching glossary aggregate above 2000 rejected") { try PromptBuilder.make(text: largeTerms.map(\.source).joined(separator: " "), source: "en", target: "ja", glossary: largeTerms) }
        let unchanged = try PromptBuilder.make(text: "Current", target: "ja")
        check(unchanged == tag + "dataset" + msg + "translation" + tag + "input" + msg + "Current" + tag + "output" + ja + msg, "successive call has no retained context/history/glossary")
        print("ALL \(passed) PROMPT FEATURE CHECKS PASSED")
    }
}
