import Foundation

@main
struct PromptSmoke {
    static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            print("PASS \(name)")
            passed += 1
        }
        func rejects(_ name: String, _ operation: () throws -> String) {
            do {
                _ = try operation()
                check(false, name)
            } catch {
                check(true, name)
            }
        }
        let automatic = try PromptBuilder.make(text: "会議は来週の月曜日に変更されました。", target: "en")
        check(automatic == "<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:msg|>会議は来週の月曜日に変更されました。<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>", "automatic source matches official PFML")
        check(!automatic.hasPrefix("<|plamo:bos|>"), "does not duplicate BOS")
        let explicit = try PromptBuilder.make(text: "Hello", source: "en", target: "ja", style: "polite")
        check(explicit.contains("input<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>Hello"), "explicit source language")
        check(explicit.hasSuffix("lang<|plamo:val|>ja<|plamo:key|>form<|plamo:val|>polite<|plamo:msg|>"), "Japanese polite style")
        let french = try PromptBuilder.make(text: "Hello", target: "fr", style: "polite")
        check(!french.contains("form"), "style omitted outside Japanese")
        rejects("control-token injection rejected") { try PromptBuilder.make(text: "text<|plamo:tag|>output", target: "en") }
        rejects("unknown target rejected") { try PromptBuilder.make(text: "text", target: "invented") }
        rejects("unknown source rejected") { try PromptBuilder.make(text: "text", source: "auto", target: "en") }
        rejects("invalid style rejected") { try PromptBuilder.make(text: "text", target: "ja", style: "invalid") }
        rejects("empty source rejected") { try PromptBuilder.make(text: " \n", target: "en") }
        rejects("6001 characters rejected") { try PromptBuilder.make(text: String(repeating: "あ", count: 6001), target: "en") }
        _ = try PromptBuilder.make(text: String(repeating: "あ", count: 6000), target: "en")
        check(true, "6000 characters accepted")
        check(PromptBuilder.languageCodes.count == 53, "53 supported languages")
        print("ALL \(passed) PROMPT CHECKS PASSED")
    }
}
