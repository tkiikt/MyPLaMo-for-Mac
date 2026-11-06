import SwiftUI
import AppKit
import NaturalLanguage

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let source: String
    let translation: String
    let target: String
}

@MainActor final class AppState: ObservableObject {
    @Published var input = ""
    @Published var source = "auto"
    @Published var target = UserDefaults.standard.string(forKey: "target") ?? "ja" { didSet { UserDefaults.standard.set(target, forKey: "target") } }
    @Published var style = UserDefaults.standard.string(forKey: "style") ?? "polite" { didSet { UserDefaults.standard.set(style, forKey: "style") } }
    @Published var message = ""
    @Published var history: [HistoryEntry] = []
    @Published var showSettings = false
    @Published var showModels = false
    @Published var showHistory = false
    @Published var useGPU = (UserDefaults.standard.object(forKey: "useGPU") as? Bool) ?? true { didSet { UserDefaults.standard.set(useGPU, forKey: "useGPU") } }
    @Published var saveHistory = UserDefaults.standard.bool(forKey: "saveHistory")
    let models = ModelManager()
    let engine = InferenceEngine()
    var translationTask: Task<Void, Never>?
    var originApp: NSRunningApplication?
    let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalTranslate/history.json")
    init() {
        if saveHistory, let data = try? Data(contentsOf: historyURL), let items = try? JSONDecoder().decode([HistoryEntry].self, from: data) { history = items }
    }
    func translate() {
        guard !engine.isBusy else { return }
        guard let url = models.selectedModelURL else { showModels = true; message = "モデルをダウンロードまたは選択してください。"; return }
        let text = input, destination = target, origin = source, form = style, gpu = useGPU
        message = ""
        UserDefaults.standard.set(target, forKey: "target")
        translationTask = Task {
            do {
                let result = try await engine.translate(text: text, source: origin == "auto" ? nil : origin, target: destination, style: form, modelURL: url, useGPU: gpu)
                if saveHistory {
                    history.insert(HistoryEntry(source: text, translation: result, target: destination), at: 0)
                    history = Array(history.prefix(100)); persistHistory()
                }
            } catch is CancellationError { message = "翻訳を中止しました。" }
            catch { message = error.localizedDescription }
        }
    }
    func cancel() { translationTask?.cancel(); engine.cancel() }
    func paste() { input = NSPasteboard.general.string(forType: .string) ?? "" }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(engine.output, forType: .string) }
    func swap() {
        let detected = NLLanguageRecognizer.dominantLanguage(for: input)?.rawValue ?? "en"
        let oldSource = source == "auto" ? (detected == "zh-Hans" ? "zh-hans" : detected == "zh-Hant" ? "zh-hant" : detected) : source
        guard PromptBuilder.languageCodes.contains(oldSource) else { message = "原文の言語を選択してから入れ替えてください。"; return }
        source = target; target = oldSource
        input = engine.output
    }
    func persistHistory() {
        UserDefaults.standard.set(saveHistory, forKey: "saveHistory")
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if saveHistory { try JSONEncoder().encode(history).write(to: historyURL, options: .atomic) }
            else { history = []; if FileManager.default.fileExists(atPath: historyURL.path) { try FileManager.default.removeItem(at: historyURL) } }
        } catch { message = "履歴を保存できません: \(error.localizedDescription)" }
    }
    func clearHistory() { history = []; persistHistory() }
}

let languages: [(String, String)] = [
("ja","日本語"),("en","英語"),("zh-hans","中国語（簡体字）"),("zh-hant","中国語（繁体字）"),("ko","韓国語"),("ar","アラビア語"),("az","アゼルバイジャン語"),("be","ベラルーシ語"),("bg","ブルガリア語"),("bn","ベンガル語"),("ca","カタルーニャ語"),("ceb","セブアノ語"),("de","ドイツ語"),("es","スペイン語"),("et","エストニア語"),("eu","バスク語"),("fa","ペルシア語"),("fr","フランス語"),("gu","グジャラート語"),("he","ヘブライ語"),("hi","ヒンディー語"),("hr","クロアチア語"),("hu","ハンガリー語"),("hy","アルメニア語"),("id","インドネシア語"),("it","イタリア語"),("jv","ジャワ語"),("ka","ジョージア語"),("kk","カザフ語"),("km","クメール語"),("lt","リトアニア語"),("lv","ラトビア語"),("ml","マラヤーラム語"),("mr","マラーティー語"),("ms","マレー語"),("my","ビルマ語"),("ne","ネパール語"),("nl","オランダ語"),("pa","パンジャーブ語"),("pl","ポーランド語"),("ru","ロシア語"),("si","シンハラ語"),("sk","スロバキア語"),("sl","スロベニア語"),("sr","セルビア語"),("sw","スワヒリ語"),("ta","タミル語"),("te","テルグ語"),("th","タイ語"),("tl","タガログ語"),("ur","ウルドゥー語"),("uz","ウズベク語"),("vi","ベトナム語")]
