# AGENTS Rules

## General

- 記号は半角とし, 句読点は `, ` と `. ` を使う.
- 依頼の目的と関連箇所を踏まえ, より良い案があれば理由とともに積極的に提案する.
- 目的達成に必要な作業は進める. 独立した追加改善は承認を得てから実施する.
- `*.md` はなるべく簡潔にし, 不要な記述は削除してよい.
- 一時的なfileやfolderは `C:/dev/tmp/reponame-taskname-timestamp` に配置し, 作業終了後に必ず削除する.

## Tools

- sub agentは使用しない.
- 質問機能は使わず, 数字だけで回答できる選択肢で質問する. 推奨案は1にする. 合理的に推測できる内容は質問しない.
- 画像生成と手動のGUI操作は行わない. GUI操作が必要な場合はuserに依頼する.
- `pwsh` では `@` をquoteする.

## Preparation

- local repositoryのpathが必要な場合は, `$HOME/local-repository-map/RepositoryMap.psm1` をimportし, `Read-LocalRepositoryMap` を実行する. PC名からprofileを自動選択する. `profiles/<profile>.json` にはそのPCの最新状態だけを反映する.
- softwareのinstall前に, `expgolemclone/envx/RULES.md` に従う. Pythonのpackagesはuvで管理する.
- 作業前に, 関連する全repository内を再帰的に探索し, 全ての `RULES.md` を読む.
- skillも同様に探索し, 必要と思われるものだけ読む.

## Design

- 二重管理しない.
- fallbackとoverrideは使わない.
- backward compatibilityの維持よりも設計のきれいさを優先する. backward compatibilityは破壊してもよい.

## Testing

- testが失敗したら原因を調査して修正する. browser操作や `skip`, `force` で回避しない.

## Version Control

`git` ではなく `jj` を使う. remoteがなければ, remote関連の指示は省略してよい.

- 作業開始時にremoteの最新状態を取得し, localより進んでいればlocalにも反映する. plan modeでも実施. 古い前提でplanしない.
- working copyに既存の変更があれば, 今回の変更とは分けてcommitし, 先にpushする.
- 作業終了後はpushし, localとremoteのbookmarkが `main` のみであることを確認する.
- `main` 以外のbookmarkやbranchの扱いに迷う場合は, userに質問する.
- Box上のfileは `git` と `jj` で管理しない.
- private repositoryではGitHub Actionsを使わない.
