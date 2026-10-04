# AGENTS Rules

## General

- 全角記号は禁止. 句読点は `, ` と `. ` を使う.
- codeとdocumentを簡潔に保つ. 二重管理, fallback, overrideは禁止.
- 問題のある指示は指摘する. 推測できない事項だけ質問し, 番号付きの推奨案を1にする.
- 作業は完了まで進め, 阻害要因は報告する. 画像生成と手動GUI操作は禁止.

## Preparation

- `$HOME/local-repository-map/RepositoryMap.psm1` の `Read-LocalRepositoryMap` で対象を特定する.
- 関連する `RULES.md`, `SKILL.md` を読む. installは `expgolemclone/envx/RULES.md` に従う.

## Design and Testing

- ECRSで設計とfolder/file構成を簡素化する. backward compatibilityに拘らず, 削除判断に迷えば質問する.
- test失敗は根本原因と同類の問題を修正し, 再発を防ぐ. skipやforceで回避しない.

## Workflow

- gitではなくjjを使い, Conventional Commitsに従う.
- taskごとに最新remote `main` を `C:/dev/tmp/<repo>-<task>-<timestamp>/repository/` へ独立cloneして作業する.
- 複数工程の `PLAN.md` と一時出力はtask領域のrepository外に置く.
- fetch, rebase, test後に `main` へ前進pushする. 更新競合時は繰り返す.
- push後にRepositoryMap登録先を排他で最新 `main` に同期する. 既存変更があれば停止する.
- 全完了後だけtask領域を削除する. 未完了領域は一括清掃しない.

## Constraints

- bookmarkはlocal, remoteとも `main` のみ. 他のbookmarkやbranchは勝手に変更せず質問する.
- expgolemclone以外にはpushしない. remoteなしは登録先で直列作業する.
- Box上ではgit/jjを使わず, private repositoryではGitHub Actionsを使わない.
