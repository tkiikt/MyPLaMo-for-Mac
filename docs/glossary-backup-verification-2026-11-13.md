# 用語集バックアップ・復元：Mac検証記録

## 対象と作業場所

Windows側の2026-11-13付申し送りを基に、Mac本体へ専用形式のバックアップ・追加式の復元を実装した。共通Chrome拡張2.3.6は変更対象外。

公開履歴の整理に合わせ、旧cloneを変更せず `/Users/hoge/Documents/Codex/MyPLaMo-for-Mac-clean` に新規cloneした。開始コミットは `da6958afa09ad1578b243e0e49a1c83f03fdcbe2`。`.stitch/` の公開履歴が空で、同ディレクトリが無視対象になっていることを確認した。

## 共通形式と保存

- 16バイトの `MyPLaMoGlossary\n`、圧縮前のJSONバイト列のSHA-256（32バイト）、GZipストリームの順。
- PascalCaseの共通DTOへ明示変換し、内部の用語IDは書き出さない。読み込み時に用語IDを生成する。用語集ID・内容・配列順序は保持する。
- 圧縮ファイルと展開後JSONは各128MiBまで。読み込み・展開中にも上限を検査する。
- 書き出しは保存先と同じディレクトリに専用一時ファイルを作り、同期・クローズ後に原子的に置換する。

## コーデックの検証

以下で **57項目すべて成功**。

```sh
swiftc Sources/LocalTranslate/GlossaryStore.swift Sources/LocalTranslate/InferenceEngine.swift Sources/LocalTranslate/GlossaryBackup.swift Tests/GlossaryBackupSmoke.swift -o /tmp/myplamo-backup-smoke
/tmp/myplamo-backup-smoke "$PWD/docs/artifacts/mac-glossary-v1.myplamo-glossary"
python3 Tests/check_glossary_backup.py Tests/Fixtures/windows-glossary-v1.myplamo-glossary docs/artifacts/mac-glossary-v1.myplamo-glossary
```

確認項目：Windows実出力の読み込み、用語ID生成、空の用語集、日本語・絵文字・引用符・改行・空白・Unicode表記・配列順序の往復、保存・置換・失敗時の元ファイル保持、短いファイル、不正ヘッダー、ハッシュ不一致、GZip破損／途中切断／余分なデータ、UTF-8／JSON／DTO不正、Version不正、各データ制約、100用語集／5,000語／UTF-16境界、入力ファイル上限、128MiBを超える圧縮データ展開の中断。

独立したPython検査では、Mac出力を標準のGZip・SHA-256・JSONで読み込み、共通のキー名だけがあること、内部用語IDが含まれないこと、Windowsサンプルと展開後データが等しいことを確認した。

## 相互運用サンプル

| ファイル | SHA-256 |
| --- | --- |
| `Tests/Fixtures/windows-glossary-v1.myplamo-glossary` | `1209c415ac8d084740e649bfd400b9ad0988155053f108b59c404ad8ae5b3ee5` |
| `docs/artifacts/mac-glossary-v1.myplamo-glossary` | `faaeb77669aabdbcf4401853d2838ecca5eb453ccfe0584b77c4fc87a4df472e` |

Mac出力はWindows側へ渡す確認用で、利用者のデータではない。「動物の用語集」2語と「空の用語集」0語を含む。**Mac出力をWindows製品コードで読み込む逆方向確認は未実施**。

## 非ASCII原語の重複判定

既存Macの `lowercased()` とWindowsの `ToUpperInvariant()` の差は、この形式実装では変更していない。例として、このMacではギリシャ文字 `σ` と `ς` は小文字化後に異なり、大文字化すると両方 `Σ` になる。ASCIIの重複テスト成功だけで非ASCIIまで完全互換とは判断しない。Windowsの実行環境でこの例と逆方向読み込みを確認する必要がある。加えて、既存MacのString比較は合成済み `café` と分解表記 `cafe\u{301}` を同方向の原語重複として拒否する。この既存検証は弱めておらず、WindowsのOrdinal比較との差があり得る。用語集ID・内容の完全一致判定は別途UTF-8比較に対応した。

## ストア・UI・総合確認

`bash Scripts/test.sh` は成功。基本プロンプト13、既存用語集28、追加プロンプト29、復元30、バックアップ57、Swift文書ヘルパー3、Python文書解析14、待ち行列5群を確認した。今回推論処理は変更しておらず、実MLX推論の再実行はしていない。

復元30項目では1対1の重複判定、同内容の複数用語集、ID衝突、再復元、上限、破損した保存ファイル、書き込み失敗、古い確認計画の拒否、翻訳用選択とrevisionの維持、非同期保存中の編集拒否を検証した。用語集IDと内容の一致はUTF-8バイトで比較し、用語IDは内容比較に含めない。

`swift build` は成功。Command Line Toolsが存在しないDeveloperライブラリ検索パスを警告したが、コンパイル・リンクは成功した。

実画面は `Tests/GlossaryBackupUI.swift` の専用アプリで、製品のGlossaryView・GlossaryStore・GlossaryBackupをそのまま使用した。保存先は一時ディレクトリ `MyPLaMo-glossary-ui-20261113`、UserDefaultsは専用suite `jp.localtranslate.glossary-backup-qa.data`。普段使いの用語集は変更していない。テスト用の翻訳言語表示は英語・日本語だけだが、本体は53言語のまま。

確認した操作：
- 空の環境ではバックアップ無効、復元有効。
- Windowsサンプルを選び、2件・2語・スキップ0件の確認後、Returnキーで復元。管理対象が先頭の用語集となり、翻訳用選択は変更されない。
- 用語集を検索で絞り、名前を未保存の状態にしてバックアップ。保存済みの全2件が含まれ、未保存の名前は含まれなかった。
- そのファイルを再度選択すると追加0件・スキップ2件となり、実行ボタンが無効。Escapeで確認をキャンセル。
- 不正なヘッダーのファイルを選ぶとエラーを表示し、既存2件を保持。
- 保存先ダイアログのEscapeでキャンセルし、既存データを保持。
- ライトの復元確認画面とダークの管理画面を目視確認。画像は作業チャット内に表示（画像ファイルへの保存は未実施）。

実画面で出力した `docs/artifacts/mac-ui-backup.myplamo-glossary` は独立したPython検査でもWindowsサンプルと内容が一致し、SHA-256は `faaeb77669aabdbcf4401853d2838ecca5eb453ccfe0584b77c4fc87a4df472e`。ファイル選択の全キャンセル経路、巨大ファイル処理中のUI負荷、実際の標準置換確認ダイアログは今回の実画面検証対象外（置換の原子性と失敗時の保護は自動テストで確認）。

`bash Scripts/build-app.sh` も成功し、通常のアプリを `dist/MyPLaMo for Mac.app` に作成、署名検証も成功した。初回検証時は配布版を更新しなかった。2026-11-14にユーザーから公開指示を受け、ライセンス案内の整理とともに0.4.0へ含める。利用者向けREADMEには検証・開発環境の情報を含めない。
