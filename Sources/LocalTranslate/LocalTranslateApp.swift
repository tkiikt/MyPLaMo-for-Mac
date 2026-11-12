import SwiftUI
import AppKit
import ServiceManagement

@main enum LocalTranslateApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    let integration = DesktopIntegration()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "MyPLaMo for Macについて", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settingsItem = appMenu.addItem(withTitle: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let edit = NSMenu(title: "編集")
        for (title, action, key) in [("元に戻す", "undo:", "z"), ("切り取り", "cut:", "x"), ("コピー", "copy:", "c"), ("貼り付け", "paste:", "v"), ("すべて選択", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = edit; menu.addItem(editItem)
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
        let appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        NSApp.appearance = appearance == "system" ? nil : NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MyPLaMo for Mac"
        window.minSize = NSSize(width: 820, height: 640)
        window.contentView = NSHostingView(rootView: MainView(state: state, models: state.models, engine: state.engine, integration: integration))
        window.isReleasedWhenClosed = false
        window.center(); self.window = window
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "MyPLaMo for Mac")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "翻訳画面を開く", action: #selector(showWindow), keyEquivalent: "")
        statusMenu.addItem(withTitle: "クリップボードを翻訳", action: #selector(translateClipboard), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q")
        for item in statusMenu.items { item.target = self }
        item.menu = statusMenu; statusItem = item
        integration.action = { [weak self] in self?.translateSelection() }
        if !UserDefaults.standard.bool(forKey: "shortcutDisabled") {
            let key = UserDefaults.standard.object(forKey: "shortcutKey") as? UInt32 ?? 17
            if !integration.register(keyCode: key) { state.message = "ショートカットを登録できません。設定から別のキーを選択してください。" }
        }
        showWindow()
        if state.models.selectedModelURL == nil { state.showModels = true }
        Task { await state.models.refreshMetadata() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc func showSettings() { showWindow(); state.showSettings = true }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func translateClipboard() { state.paste(); showWindow(); state.translate() }
    func translateSelection() {
        state.originApp = NSWorkspace.shared.frontmostApplication
        if state.originApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { state.originApp = nil }
        if let text = integration.selectedText(), !text.isEmpty {
            state.input = text; showWindow(); state.translate()
        } else {
            showWindow()
            state.message = "選択テキストを取得できませんでした。コピーして「貼り付け」を押してください。他のアプリの選択文を取得するには設定でアクセシビリティを許可します。"
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state.bridge.stop(); state.cancel(); state.engine.shutdown()
        DispatchQueue.main.async { self.state.models.pause { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}

struct AppSettings: View {
    @ObservedObject var state: AppState
    let integration: DesktopIntegration
    @AppStorage("shortcutDisabled") var shortcutDisabled = false
    @AppStorage("shortcutKey") var shortcutKey = 17
    @AppStorage("appearance") var appearance = "system"
    @ViewState private var login = SMAppService.mainApp.status == .enabled
    @ViewState private var error = ""
    var body: some View {
        Form {
            Toggle("Apple GPUを使用", isOn: $state.useGPU)
            Toggle("翻訳履歴をこのMacに保存（最大100件）", isOn: $state.saveHistory)
                .onChange(of: state.saveHistory) { _, _ in state.persistHistory() }
            Button("履歴をすべて削除", role: .destructive) { state.clearHistory() }
            Toggle("ショートカットを無効にする", isOn: $shortcutDisabled).onChange(of: shortcutDisabled) { _, value in
                if value { integration.disable() } else { register() }
            }
            Picker("呼び出しキー（⌥⌘）", selection: $shortcutKey) {
                Text("T").tag(17); Text("Y").tag(16); Text("J").tag(38)
            }.onChange(of: shortcutKey) { _, _ in if !shortcutDisabled { register() } }
            Button("選択テキスト取得を許可…") { integration.requestAccessibility() }
            Toggle("ログイン時に起動", isOn: $login).onChange(of: login) { _, value in
                do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { self.error = error.localizedDescription }
            }
            Picker("外観", selection: $appearance) { Text("システム").tag("system"); Text("ライト").tag("light"); Text("ダーク").tag("dark") }
                .onChange(of: appearance) { _, value in NSApp.appearance = value == "system" ? nil : NSAppearance(named: value == "dark" ? .darkAqua : .aqua) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Text("翻訳処理はこのMac内で完結します。ネットワークはモデル情報の取得・ダウンロードに使用します。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 460)
    }
    func register() {
        if !integration.register(keyCode: UInt32(shortcutKey)) { error = "このキーは使用できません。別のキーを選んでください。" } else { error = "" }
    }
}
