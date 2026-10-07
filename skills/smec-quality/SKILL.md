---
name: smec-quality
description: smec-secondのPDF原本照合, HTML校正, 採点基準audit, quality branchの統合に使う. 完成ページを10ページごとにmainへ統合し, 未統合の蓄積を防ぐ.
---

# smec-second quality

RepositoryMapで `expgolemclone/smec-second` を特定し, 対象repositoryの `RULES.md`, `docs/parallel-quality.md`, `docs/html-quality.md` を読んで従う. PDF OCRを修正するときは `docs/pdf-reocr.md` も読む. 所有権とtask操作は共通agent workflowに従う.

## 10ページごとのmain統合

- 原本照合と必要な検証が完了したHTMLの `source_file` を重複なしで数える. 再録, 同じページの再修正, OCR証拠だけの更新は別ページとして加算しない.
- 完成10ページごとに必ずmainへ統合する. 10ページに達したら次のページの作業へ進まず, 最新mainへのfetch/rebase, 影響範囲のtest, codeだけのmainへの前進push, 登録先の排他同期, repoルールに従うdeployを完了する.
- 設問の続きが10ページの境界をまたぐ場合は手前の完成範囲で統合し, 次のtaskで続きを扱う. task終了時も10ページ未満の完成分を統合し, 次回へ溜めない.
- 統合, test, 同期, deployに失敗したら新しいページへ進まず原因を修正する. 解消できない阻害要因は報告し, 未完了taskを保持する. 未検証ページを統合しない.
- 既存quality branchの内容は所有権と明示的な引き継ぎを確認したうえで, mainで既に反映された修正を除き, 完成10ページ以下の単位で統合する. branch全体の一括mergeや無断変更はしない.
