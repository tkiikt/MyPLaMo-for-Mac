# ライセンス・著作権表示

Built with PLaMo。

## アプリ

MyPLaMoの自作部分には、同梱の `LICENSE.txt` に記載したMIT Licenseを適用します。第三者製ソフトウェアには各権利者のライセンスが適用されます。

## PLaMoモデル

PLaMo 3 TranslateはPreferred Networksが提供するモデルです。モデルの利用条件は `Licenses/PLaMo-Community-License-ja.txt`（日本語）および `Licenses/PLaMo-Community-License-en.txt`（英語）を参照してください。

モデルの重みはこのZIPには含まれていません。アプリから別途取得するモデルには、取得元のモデルに付属するライセンスが適用されます。

公式配布元：https://huggingface.co/collections/pfnet/plamo-3-translate

## 同梱ソフトウェア

アプリにはPython、MLX、MLX-LM、Transformers、NumPyなどのソフトウェアを同梱しています。

- `Licenses/Runtime/`：Pythonとランタイム依存ライブラリのライセンス・著作権表示
- `Licenses/Python-Packages/`：各Pythonパッケージのライセンス・著作権表示・配布メタデータ
- `Licenses/Package-Notices/`：パッケージ本体内に含まれる追加のライセンス・著作権表示
- `Licenses/Additional/`：パッケージの同梱文書を補うライセンス原文と出典
- `Licenses/PACKAGES.txt`：同梱パッケージ名・バージョンと対応する文書の一覧

パッケージ内の第三者ライセンスやNOTICEも、提供元の文書に含まれる形で保持しています。アプリ本体の `Contents/Resources/runtime/` 内にも元のライセンス・配布メタデータを保持しています。

同梱バイナリはアプリ内で読み込めるようライブラリ参照先の変更とアドホック署名を行っています。これらの変更によって各ソフトウェアのライセンスが置き換わることはありません。
