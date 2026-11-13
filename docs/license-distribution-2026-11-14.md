# ライセンス案内の整理（2026-11-14）

公式ページとPFN公式Hugging Faceの規約を確認。11月9日改訂は公式Hugging Faceの英語規約末尾に記載されている。Xの告知URLは取得時403のため、投稿本文は確認できなかった。

- https://plamo.preferredai.jp/info/plamo-community-license-ja
- https://huggingface.co/pfnet/plamo-3-translate-8b/blob/main/LICENSE/en

公式規約第4条ではモデル又は派生モデルを第三者へ提供する際に規約コピーの提供を求める。URLだけでこの義務を置き換えられるとは案内しない。

本アプリの配布物にはPFNのモデル重み・モデル固有コード・トークナイザーを含めない。MLX-LMに含まれるPLaMo実装はAppleのMITライセンスであり、その表示は保持する。モデルは別途公式リポジトリからダウンロードし、そのLICENSEファイルも取得対象に含めたままとする。

ルートLICENSEとLICENSE-MITはMITのまま維持する。アプリ側に転載していたPLaMo規約の固定コピーは削除し、Resources/PLaMo-MODEL-LICENSE.mdに公式URL・配布対象・モデル再配布時の注意を整理した。同梱のPython・MLX等のライセンス本文とNOTICEは削除しない。ビルド時に旧リソースも除去し、以前のビルドの規約本文が残らないようにする。

将来モデルを同梱する構成へ変更する場合は、その配布に適用される規約コピーと表示を改めて同梱する必要がある。
