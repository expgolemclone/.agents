# AGENTS Rules

## General

- 記号は半角とし, 句読点は `, ` と `. ` を使う.
- `*.md` はなるべく簡潔にし, 不要な記述は削除する.
- 一時的なfileやfolderは `C:/dev/tmp/reponame-taskname-timestamp` に配置し, 作業終了後に削除する.
- 依頼の範囲内で実行可能な作業をすべて完了するまで終了しない. 続行できない作業は阻害要因を報告する.
- userへの迎合は禁止. 目的, 前提, 手段の妥当性を検証し, 問題があれば根拠と代案を示す. 依頼の変更が必要なら, 問題のある方針での実行を止め, より適切な目的や方針を提案してuserに確認する.
- AIの理解不足をuserの指示の誤りと決めつけず, 判断に必要な情報を調査する.

## Tools

- 調査や合理的な推論で解消できる問題はAIが判断する. userの意図や選好など, userに確認しなければ決められない事項だけ質問する.
- 質問では数字の選択肢を示し, 推奨案は1にする.
- 画像生成と手動のGUI操作は行わない. 必要ならuserに依頼する.

## Preparation

- 複数工程にわたる実装や継続作業では, planを `PLAN.md` にtodo listで書き, 進捗を更新する. 全項目が `- [x]` になったら削除する. 単純な変更や回答だけの相談では作成不要.
- local repositoryのpathが必要な場合は, `$HOME/local-repository-map/RepositoryMap.psm1` をimportし, `Read-LocalRepositoryMap` を実行する.
- taskに関係ある `RULES.md`, `SKILL.md` を読む.
- softwareのinstall時は, `expgolemclone/envx/RULES.md` に従う.

## Design

- 設計のきれいさを最優先し, ECRS(排除, 統合, 再配置, 簡素化)の順に改善を検討する.
  - backward compatibilityは破壊して良い.
  - 分かりづらいfolder構成は放置せず直す.
- 二重管理禁止. 同じ事実や設定に複数の独立した正本を持たせない. 派生物は正本から生成し, 個別に更新しない.
- fallbackは禁止. 必要な値や機能の欠如, または処理の失敗を, 代替の値や処理で補って継続する仕組みを作らない.
- overrideは禁止. 既存の定義を残したまま, 別の定義で設定や動作を上書きしない. 変更は正本の定義に反映する.
- 禁止事項は名称ではなく構造と挙動で判定する.
- 根本原因を解決する. 同様の問題はすべて解決する. 再発防止までやる.

## Testing

- testが失敗したら原因を調査して修正する. `skip`, `force` で回避しない.

## Version Control

この節はrepository内のfileを変更するtaskに適用する. 回答だけの相談やレビューでは, この節の手続きは不要.

`git` ではなく `jj` を使う. remoteがなければ関連指示は省略.

- 作業開始時にremoteの最新状態を取得し, localより進んでいればlocalにも反映する. 古い前提でplanしない.
- working copyに既存の変更があれば, 内容と出所, 公開可否を確認し, 今回の変更とは分けてcommitし, 先にpushする. 公開してよいか確認できない変更はpushせず, userに確認する.
- commit messageはConventional Commitsに従い, `<type>[optional scope][!]: <description>` とする.
- 作業終了後はpushし, localとremoteのbookmarkが `main` のみであることを確認する.
  - `main` 以外のbookmarkやbranchの扱いに迷う場合はuserに質問する.
  - expgolemclone 以外のuserのrepositoryにpushしない.
- Box上のfileは `git` と `jj` で管理しない.
- private repositoryではGitHub Actionsを使わない.
