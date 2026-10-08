---
name: smec-quality
description: smec-secondのPDF原本照合, HTML校正, 採点基準auditに使う. repositoryの品質契約と小バッチ統合手順に従い, 完成範囲をmainへ反映する.
---

# smec-second quality

RepositoryMapで `expgolemclone/smec-second` を特定し, 対象repositoryの `RULES.md`, `docs/parallel-quality.md`, `docs/html-quality.md` を読んで従う. 原本の取得と版確認は `docs/source-pdfs.md`, PDF OCRの修正は `docs/pdf-reocr.md` も読む.

## 作業開始

所有権, task clone, 実行許可, 引き継ぎと完了操作は共通agent workflowのhelperに従う. 想定外の旧quality branchを検出してhelperが停止したら, branchを保全してuserへ確認する. 明示承認された保全はhelperのtask単位のbranch名とtip確認で記録し, failed startのcloneを実装へ転用しない. 保全は所有権や統合許可ではない. 所有権の確認だけで停止条件を回避せず, 明示承認された移行手順が確定するまで旧branchの統合を開始しない.

## 品質と統合

原本証拠と完了判定は `docs/html-quality.md`, ページの数え方, 設問と採点条件の依存関係を閉じた統合境界, 小バッチの上限とtask切り替えは `docs/parallel-quality.md` を正本とする. 統合後の続きは最新mainから新しいtask cloneで行い, mainへのpushが確認されたcloneを編集しない.
