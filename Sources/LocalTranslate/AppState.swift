import SwiftUI
import AppKit
import NaturalLanguage
import Combine

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let source: String
    let translation: String
    let target: String
}

@MainActor final class AppState: ObservableObject {
    @Published var input = ""
    @Published var output = ""
    @Published var desktopBusy = false
    @Published var chromeEnabled = false
    let bridge = ChromeBridge()
    private var desktopActive = false
    private var outputSubscription: AnyCancellable?
    lazy var queue = TranslationQueue(engine: engine)
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
        outputSubscription = engine.$output.sink { [weak self] value in
            guard let self, self.desktopActive else { return }; self.output = value
        }
        if saveHistory, let data = try? Data(contentsOf: historyURL), let items = try? JSONDecoder().decode([HistoryEntry].self, from: data) { history = items }
    }
    func translate() {
        guard !desktopBusy else { return }
        guard let url = models.selectedModelURL else { showModels = true; message = "モデルをダウンロードまたは選択してください。"; return }
        let text = input, destination = target, origin = source, form = style, gpu = useGPU
        message = ""
        UserDefaults.standard.set(target, forKey: "target")
        desktopBusy = true
        translationTask = Task {
            defer { desktopActive = false; desktopBusy = false }
            do {
                let result = try await queue.run(text: text, source: origin == "auto" ? nil : origin, target: destination, style: form, modelURL: url, useGPU: gpu, onStart: { self.desktopActive = true; self.output = "" })
                output = result
                if saveHistory {
                    history.insert(HistoryEntry(source: text, translation: result, target: destination), at: 0)
                    history = Array(history.prefix(100)); persistHistory()
                }
            } catch is CancellationError { message = "翻訳を中止しました。" }
            catch { message = error.localizedDescription }
        }
    }
    func cancel() { translationTask?.cancel(); if !desktopBusy { engine.cancel() } }
    func setChromeEnabled(_ enabled: Bool) {
        chromeEnabled = enabled
        if enabled {
            bridge.start { [weak self] text in
                guard let self, self.chromeEnabled else { throw CancellationError() }
                guard let url = self.models.selectedModelURL else { throw TranslationError.invalidInput("MyPLaMo for MacでMLXモデルを準備してください。") }
                return try await self.queue.run(text: text, source: nil, target: "ja", style: self.style, modelURL: url, useGPU: self.useGPU)
            }
        } else { bridge.stop() }
    }
    func paste() { input = NSPasteboard.general.string(forType: .string) ?? "" }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) }
    func swap() {
        let detected = NLLanguageRecognizer.dominantLanguage(for: input)?.rawValue ?? "en"
        let oldSource = source == "auto" ? (detected == "zh-Hans" ? "zh-hans" : detected == "zh-Hant" ? "zh-hant" : detected) : source
        guard PromptBuilder.languageCodes.contains(oldSource) else { message = "原文の言語を選択してから入れ替えてください。"; return }
        source = target; target = oldSource
        input = output
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
