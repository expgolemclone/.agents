# AGENTS Rules

## General

- 全角記号は禁止.
  句読点は `, ` と `. ` を使う.

- codeとdocumentは簡潔にし, 二重管理, fallback, overrideは禁止.
  - documentの追加は明示依頼時のみ.
    既存記述は変更に合わせて修正する.

- 問題のある指示は指摘する.
  推測できない事項だけ質問し, 番号付きの推奨案を1にする.

- 作業は完了まで進め, 阻害要因は報告する.
  画像生成と手動GUI操作は禁止.

- `plan` とuserが入力した場合, `do` まで調査と提案だけ行う.
  調査用fileや検証は可.
  実装, 運用変更, commit, pushはしない.

## Preparation

- `$HOME/local-repository-map/RepositoryMap.psm1` の
  `Read-LocalRepositoryMap` で対象を特定する.

- 関連する `RULES.md`, `SKILL.md` を読む.
  共通skillは `$HOME/.agents/skills/`,
  repo固有skillは対象repoの `skills/` を正本とする.

- 言語を問わずpackage, tool, runtimeの導入から実行, 更新, 廃止, 検証まで
  `expgolemclone/envx/RULES.md` に従う.

## Design and Testing

- ECRSで設計とfolder/file構成を簡素化する.
  backward compatibilityに拘らず, 削除判断に迷えば質問する.

- test失敗は根本原因と同類の問題を修正し, 再発を防ぐ.
  skipやforceで回避しない.

## Workflow

- gitではなくjjを使い, Conventional Commitsに従う.

- `$HOME/.agents/workflow/AgentWorkflow.psm1` をimportし,
  `Get-AgentWorkflowHelp` に従う.
  `workflow/` のcodeはトラブル調査時だけ読む.

## Constraints

- bookmarkはlocal, remoteとも `main` と未完了taskの `handoff/*` のみ.
  その他は勝手に変更せず質問する.

- expgolemclone以外にはpushしない.
  remoteなしは登録先で直列作業する.

- Box上ではgit/jjを使わず,
  private repositoryではGitHub Actionsを使わない.
