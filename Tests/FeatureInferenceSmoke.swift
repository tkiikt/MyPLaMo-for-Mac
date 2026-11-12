import Foundation

@main struct FeatureInferenceSmoke {
    @MainActor static func main() async {
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = InferenceEngine(), queue: TranslationQueue
        queue = TranslationQueue(engine: engine)
        defer { engine.shutdown() }
        do {
            let terms = [GlossaryTerm(source: "dashboard", target: "管理画面", from: "en", to: "ja")]
            let ja = try await queue.run(text: "Open the dashboard.", source: "en", target: "ja", style: "polite", modelURL: model, useGPU: true, context: "Software user guide", glossary: terms, useContext: true)
            guard !ja.isEmpty else { fatalError("Empty translation") }
            print("MLX glossary en→ja:",ja)
            let en = try await queue.run(text: "管理画面を開いてください。", source: "ja", target: "en", modelURL: model, useGPU: true, context: "Software user guide", glossary: [GlossaryTerm(source:"管理画面",target:"dashboard",from:"ja",to:"en")], useContext: true)
            print("MLX glossary ja→en:",en)
            let prose = try await queue.run(text: "  The dashboard shows active tasks.\n\nOpen it to check the progress.  ", source: "en", target: "ja", style:"polite", modelURL:model,useGPU:true,context:"Software manual",glossary:terms,useContext:true)
            guard prose.hasPrefix("  "), prose.hasSuffix("  "), prose.contains("\n\n") else { fatalError("Paragraph whitespace lost") }
            print("MLX context paragraphs:",prose)
            let json = "{\r\n  \"title\": \"Open the dashboard.\", \"count\": 2, \"url\": \"https://example.com\"\r\n}"
            let document = try await queue.run(text:json,source:"en",target:"ja",style:"polite",modelURL:model,useGPU:true,glossary:terms,useContext:true,format:.json)
            let parsed = try JSONSerialization.jsonObject(with:Data(document.utf8)) as! [String:Any]
            guard parsed["count"] as? Int == 2, parsed["url"] as? String == "https://example.com", document.contains("\r\n") else { fatalError("JSON structure lost") }
            print("MLX JSON:",document)
            let yaml = "# keep\r\ntitle: Open the dashboard.\r\nactive: true\r\n"
            let y = try await queue.run(text:yaml,source:"en",target:"ja",modelURL:model,useGPU:true,glossary:terms,useContext:false,format:.yaml)
            guard y.contains("# keep\r\n"), y.contains("active: true\r\n") else { fatalError("YAML structure lost") }
            print("MLX YAML:",y)
            print("PASS real MLX features (actual glossary outputs recorded; model adherence is not guaranteed)")
        } catch { print("FAIL",error.localizedDescription); exit(1) }
    }
}
