import Foundation
@main struct ChromeBridgeSmoke {
    @MainActor static func main() async {
        let bridge = ChromeBridge()
        var translateCount = 0
        bridge.start(metadata: {
            ["glossaries": [["id": "test-glossary", "name": "Software", "count": 1]],
             "glossaryRevision": "test-revision", "glossaryError": "", "modelId": "test-mlx-model",
             "languages": PromptBuilder.languageCodes.sorted().map { ["id": $0, "name": $0] },
             "translateCount": translateCount]
        }, translate: { request in
            translateCount += 1
            if let glossary = request.glossaryID, glossary != "test-glossary" {
                throw TranslationError.invalidInput("指定した用語集が見つかりません。")
            }
            if request.text == "slow" { try await Task.sleep(for: .seconds(16)) }
            if request.text == "options" {
                let data = try JSONSerialization.data(withJSONObject: ["source": request.source ?? "", "target": request.target, "style": request.style ?? "", "glossaryID": request.glossaryID ?? "", "context": request.context])
                return String(decoding: data, as: UTF8.self)
            }
            return "訳:" + request.text
        })
        for _ in 0..<30 {
            if let error = bridge.error { print(error); exit(1) }
            if bridge.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard bridge.isRunning else { exit(1) }
        print("READY"); fflush(stdout)
        try? await Task.sleep(for: .seconds(120))
        bridge.stop()
    }
}
