import SwiftUI

// Manual UI checks use a separate app identity, defaults suite and temporary data.
// The production GlossaryView is unchanged; only this harness's language labels are reduced.
let languages = [("en", "英語"), ("ja", "日本語")]

@main struct GlossaryBackupUI: App {
    @StateObject private var store: GlossaryStore
    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyPLaMo-glossary-ui-20261113")
        _store = StateObject(wrappedValue: GlossaryStore(directory: directory,
            defaults: UserDefaults(suiteName: "jp.localtranslate.glossary-backup-qa.data")!))
    }
    var body: some Scene {
        WindowGroup("用語集バックアップ・復元の確認") {
            GlossaryView(store: store)
                .preferredColorScheme(Bundle.main.object(forInfoDictionaryKey: "QAUseDarkMode") as? Bool == true ? .dark : .light)
        }.defaultSize(width: 920, height: 680)
    }
}
