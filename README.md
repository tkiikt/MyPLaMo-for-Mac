# MyPLaMo for Mac

PLaMo 3 Translateの公式MLX-4bitモデルを使う、SwiftUI / AppKit製のmacOSネイティブ翻訳アプリです。Built with PLaMo。モデル取得後の翻訳はMac内で完結します。

## 起動と翻訳

`dist/MyPLaMo for Mac.app` を開いてください。推論に必要なPython・MLXはアプリに同梱しています。現在のビルドはApple Silicon / macOS 27.2以降用です。

このMacでは0.8Bモデルを取得・検証済みで、保存先 `ModelsMLX` とモデル選択を設定しています。別のMacでは「モデル」から取得してください。モデルは配布ZIPに含めていません。

- 原文を入力して「翻訳する」、または ⌘Return。53言語、言語自動判定、日本語の敬体・常体、逐次表示、中止に対応。
- ⌥⌘Tで呼び出せます。設定でT / Y / Jを選択できます。
- 選択文の取得はmacOSのアクセシビリティ許可が必要です。手動貼り付けは許可不要です。
- メニューバーから再表示・クリップボード翻訳・終了ができます。ウィンドウを閉じても常駐します。
- 「元のアプリへ挿入」は確認後に現在の挿入位置へ貼り付けます。

## モデル

公式コレクションの0.8B / 2B / 8B / 31BのMLX-4bitに対応。ダウンロード容量は約0.98 / 2.41 / 6.07 / 18.66 GBです。実行時には追加のメモリが必要です。

保存先変更、外部ドライブ、一時停止・再開、既存モデルの検証、モデル移動に対応します。配布元のリビジョンを固定し、重みはSHA256、その他のファイルはGit blobハッシュで照合します。公式モデルに必要なPythonコードも同じリビジョンから取得します。保存済みモデルは検証記録とファイルサイズを確認します。

モデルは同時に1つだけ読み込みます。Apple GPUが標準で、設定からCPUに変更できます。入力上限は6,000文字、トークン数も検査します。出力上限に達した場合は未完の案内を表示します。モデル利用条件はダウンロード画面のPLaMo Community Licenseを確認してください。

## ChromeでWeb翻訳

Windows版の拡張機能を共通化しています。専用の連携アプリやレジストリ設定は不要です。

1. Macアプリを起動してモデルを選び、「Chromeからの翻訳を受け付ける」をオンにします。
2. Chromeの `chrome://extensions` でデベロッパーモードをオンにし、「パッケージ化されていない拡張機能を読み込む」から `chrome/extension` を選びます。このMacでは読み込み済みです。
3. ページ上で右クリックし「MyPLaMoでWEB全体を翻訳」、または拡張アイコンを押します。
4. 「原文に戻す」または拡張アイコンで元に戻せます。

本文・リンク・ボタン・後から追加された文章を日本語に翻訳します。PDF、画像の文字、埋め込みフレーム、コード、入力欄は対象外です。Chrome内部ページなど、拡張が動けないページでは利用できません。

本体と拡張は選択中のモデル・GPU・文体を共有し、同じエンジンで順番に処理します。ページ翻訳で本体の入力・結果・履歴は書き換えません。受付は起動ごとにオフで、オンの間だけ127.0.0.1:47832で待ち受けます。拡張IDと接続先はWindows版と共通です。

## 設定とデータ

履歴保存は初期状態でオフです。有効時は最大100件をこのMacに保存します。原文・訳文を外部APIへ送りません。Hugging Faceへの通信はモデル情報取得・ダウンロードに使用します。

既存設定との互換性のため、設定IDは `jp.localtranslate.mac`、履歴は `~/Library/Application Support/LocalTranslate` を引き継いでいます。MLXの管理情報は `~/Library/Application Support/MyPLaMo` を使用します。旧GGUFモデルは削除しませんが、新版では使用しません。

## 開発と検証

Command Line Tools / Swift 6.4、Homebrew Python 3.13で開発しています。Xcode本体は不要です。

```sh
Scripts/setup-mlx.sh
Scripts/build-app.sh
Scripts/test.sh ModelsMLX/plamo-3-translate-0.8b-MLX-4bit
node --test chrome/tests/bridge.test.cjs
```

`Scripts/package-mlx.sh 新しい出力フォルダ` で推論環境を再作成できます。依存バージョンは `Runtime/requirements-mlx.lock` に固定しています。ビルドは既存のアプリ内runtimeを再利用するため、依存更新時はアプリ内のruntimeを再作成したものに置き換え、再ビルドしてください。

確認済み：0.8Bの取得・中断/再開・ハッシュ照合、GPU日英/英日、CPU英日、読み込み中/生成中の中止と再翻訳、同梱環境での画面操作、Chromeのページ翻訳・動的追加・原文復帰・受付オフ時の案内、WebSocketの不正接続拒否とハートビート、拡張の5項目、プロンプトの13項目。

2B / 8B / 31Bは一覧・取得機能に対応していますが実推論は未検証です。Windows実機での今回の拡張更新の確認も未実施です。選択文取得・直接挿入・ログイン時起動・実キーボードのグローバルショートカットは、権限や通常操作での追加確認が残ります。

アドホック署名のローカル開発版です。Developer ID署名・Apple公証は未実施です。現在の同梱ライブラリに合わせ最低OSを27.2にしています。旧OSは未検証です。

## 参照とライセンス

- [公式MLXモデルを含むコレクション](https://huggingface.co/collections/pfnet/plamo-3-translate)
- [Windows版・共通Chrome拡張の元リポジトリ](https://github.com/tkiikt/MyPLaMo)
- [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-ja)

アプリと拡張のライセンスは `LICENSE-MIT`、モデル利用条件は `Resources/PLaMo-LICENSE-ja.txt` を参照してください。ランタイムのライセンスはアプリ内 `Contents/Resources/runtime/Licenses` と各依存パッケージのdist-infoに同梱しています。`model-reference.md` は旧GGUF版開発時の参考資料です。
