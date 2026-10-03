# AGENTS Rules

## General

- 記号は半角とし, 句読点は `, ` と `. ` を使う.
- `*.md` はなるべく簡潔にし, 不要な記述は削除してよい.
- 一時的なfileやfolderは `C:/dev/tmp/reponame-taskname-timestamp` に配置し, 作業終了後に削除する.

## Tools

- sub agentは使用しない.
- 質問機能は使わず, 数字の選択肢で質問する. 推奨案は1にする. 合理的に推測できる内容は質問しない.
- 画像生成と手動のGUI操作は行わない. 必要ならuserに依頼する.

## Preparation

- local repositoryのpathが必要な場合は, `$HOME/local-repository-map/RepositoryMap.psm1` をimportし, `Read-LocalRepositoryMap` を実行する.
- 作業前に, 関連する全repository内を再帰的に探索し, 全ての `RULES.md`, `SKILL.md` を読む.
- softwareのinstall前に, `expgolemclone/envx/RULES.md` に従う.

## Design

- 二重管理禁止.
- fallbackとoverrideは禁止.
- 根本原因を解決する. 同様の問題はすべて解決する. 再発防止までやる.
- 設計のきれいさを最優先する.
  - backward compatibilityは破壊して良い.
  - 分かりづらいfolder構成は放置せず直す.
- userがほんの少しでも愚かな指示をしてきたらtaskを行わない. 痛烈に指摘し指示の変更を求める.

## Testing

- testが失敗したら原因を調査して修正する. `skip`, `force` で回避しない.

## Version Control

`git` ではなく `jj` を使う. remoteがなければ, 関連指示は省略.

- 作業開始時にremoteの最新状態を取得し, localより進んでいればlocalにも反映する. plan modeでも実施. 古い前提でplanしない.
- working copyに既存の変更があれば, 今回の変更とは分けてcommitし, 先にpushする.
- 作業終了後はpushし, localとremoteのbookmarkが `main` のみであることを確認する.
  - `main` 以外のbookmarkやbranchの扱いに迷う場合はuserに質問する.
  - expgolemclone 以外のuserのrepositoryにpushしない.
- Box上のfileは `git` と `jj` で管理しない.
- private repositoryではGitHub Actionsを使わない.
