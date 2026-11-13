# ライセンス・著作権表示

Built with PLaMo。

## アプリ

MyPLaMoの自作部分には、同梱の `LICENSE.txt` に記載したMIT Licenseを適用します。第三者製ソフトウェアには各権利者のライセンスが適用されます。

## PLaMoモデル

PLaMo 3 TranslateはPreferred Networksが提供するモデルです。利用条件・改訂情報は公式規約をご確認ください。

https://plamo.preferredai.jp/info/plamo-community-license-ja

モデルの重み・モデル固有コード・トークナイザーはこのZIPには含まれていません。モデルはアプリから別途取得します。取得したモデルに付属するライセンス・著作権表示も保持してください。

`PLaMo-MODEL-LICENSE.md` に公式URLと配布対象の区別を記載しています。モデル又は派生モデルそのものを再配布する際の規約コピー提供義務は、このURL案内で代替するものではありません。

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
