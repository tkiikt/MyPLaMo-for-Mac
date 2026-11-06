# LocalTranslate for macOS

PLaMo 3 Translateを使う、SwiftUI / AppKit製のローカル翻訳アプリです。モデル取得後は翻訳にインターネット接続を必要としません。

## 起動

`dist/LocalTranslate.app` をダブルクリックしてください。現在のビルドはこのMac（Apple M5 / macOS 27.2）用です。推論エンジンはアプリ内に同梱済みです。

検証済みの0.8Bモデルは `Models/plamo-3-translate-0.8b-Q4_K_M.gguf` に保存しています。このMacのアプリにはこの保存先と0.8Bの選択を設定済みです。モデルはアプリ本体に同梱していません。

- 原文を入力して「翻訳する」、または ⌘Return。
- ⌥⌘Tで他のアプリから呼び出し。キーは設定でT / Y / Jから変更できます。
- 選択文の直接取得には、macOSの「プライバシーとセキュリティ → アクセシビリティ」でLocalTranslateの許可が必要です。許可がない場合も手動貼り付けで利用できます。
- メニューバーの吹き出しから画面を再表示、クリップボード翻訳、終了ができます。ウィンドウを閉じても常駐します。
- 「元のアプリへ挿入」は確認後、元アプリの現在の挿入位置へ訳文を貼り付けます。選択中の文字がある場合は置き換えます。

## モデル管理

「モデル」から0.8B / 2B / 8B / 31Bを選択できます。公式GGUF Q4_K_Mを使用し、容量とSHA256を公式配布元から取得します。ダウンロード後はサイズ・SHA256を照合します。

- 保存先は任意のフォルダや外部ドライブに指定可能。
- 一時停止・再開・再試行に対応。終了時もダウンロード再開情報を保存します。
- 「保存先を選択」はそのフォルダの既存モデルを検出します。「モデルを移動」は保存済みモデルを検証付きで移動します。
- 既存モデルの検出はファイル名とサイズによります。新規ダウンロードと移動ではSHA256も検証します。
- モデルは同時に1つだけ使用。モデル/GPU設定の変更後、次回翻訳で読み込み直します。
- 新規ダウンロード前に、画面からPLaMo Community Licenseを確認して同意してください。利用条件の確認や登録が必要な場合は利用者が行ってください。

## 設定とプライバシー

53言語、言語自動検出、日英などの双方向翻訳、日本語の敬体・常体、Apple GPU / CPU切り替え、翻訳中止、逐次表示に対応します。入力は1回6,000文字までで、実際のトークン数も検査します。出力が途中で上限に達した場合は未完の表示を出します。

履歴は初期状態で保存しません。有効にした場合は最大100件をこのMacだけに保存します。設定から保存を無効化、または全削除できます。言語・文体・GPU設定・モデル選択・保存先・外観・ショートカット設定は保存されます。

ログイン時起動は設定から明示的に有効化します。macOS側で承認が必要になる場合があります。

設定はアプリのUserDefaults、履歴とモデルメタデータは `~/Library/Application Support/LocalTranslate` に保存します。モデル情報の取得・ダウンロードはHugging Faceへ通信します。翻訳の原文・訳文は外部APIへ送信しません。推論サーバーは認証付きで127.0.0.1だけに接続します。

## 開発・再ビルド

Swift 6.4 / Command Line Tools、Homebrewが導入済みの環境で開発しています。Xcode本体は不要です。

```sh
brew install llama.cpp
Scripts/build-app.sh
Scripts/test.sh
Scripts/test.sh Models/plamo-3-translate-0.8b-Q4_K_M.gguf
```

`Scripts/package-engine.sh` はHomebrewからエンジンと依存ライブラリ・ライセンスをコピーし、アプリ内の参照に変更して署名します。エンジン更新時は `REBUILD_ENGINE=1 Scripts/build-app.sh`。今回の同梱エンジンは llama.cpp 0.9.0 / build 12110 / cd959bae9。HomebrewのバイナリがmacOS 27.2を要求するため、完成アプリも27.2以上として設定しています。ソース側はmacOS 14のAPIを基準にしていますが、旧OSでの動作は未検証です。

CLTのSDKには新しいSwiftUI Stateマクロのプラグインが含まれないため、`ViewState`型エイリアスで既存のproperty wrapperを使用します。CLTにはXCTestもないため、通常の検証は `Scripts/test.sh` で実行します。`swift test` はXcodeのXCTest環境が必要です。

## 確認済み・未確認

確認済み：リリースビルド、署名検証、同梱エンジンでの画面からの英日翻訳、0.8Bのダウンロード中断/再開・SHA256照合、GPU日英/英日、CPU英日、読み込み中・生成中の中止と再翻訳、PFML/入力制限の13項目。

2B / 8B / 31Bは選択・ダウンロード機能を実装していますが、実モデルを取得しての推論確認は0.8Bのみです。他アプリの選択文取得と直接挿入はアクセシビリティ許可が必要で、この開発作業では許可設定を変更していません。ログイン時起動も未有効化・未検証です。グローバルショートカットは登録処理を実装済みですが、自動操作環境ではキーイベントの到達を確認できていません。通常のキーボードでの⌥⌘Tの確認が残っています。

この成果物はローカル開発用のアドホック署名です。別のMacへの一般配布向けDeveloper ID署名・Apple公証は行っていません。

## 公式資料

- [PLaMo 3 Translate GGUF](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF)
- [PFNの技術解説](https://www.preferred.jp/ja/blog/tech/plamo-3-translate-weight-release)
- [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-ja)

`model-reference.md` は実装時に参照した公式モデルカードです。推論エンジンのライセンスはアプリ内の `Contents/Resources/engine/Licenses` に格納しています。
