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

- 目的を満たす最も単純で一貫した設計を選ぶ. ECRS(排除, 統合, 再配置, 簡素化)の順に検討し, 不要な要件や仕組みも見直す.
- 情報の正本と責務を明確にする. 複製が必要なら, 正本との整合性を保つ方法も設計する.
- fallbackやoverrideは, 要件を満たす効果と複雑化のコストを比較して採否を決める. 失敗や優先順位を明示し, 不具合や競合を隠さない.
- 既存構成やbackward compatibilityの維持を目的にしない. 必要なら構成変更や互換性破壊を選び, 効果と影響を確認する.
- 根本原因を調べ, 依頼の解決に必要な関連箇所を一貫して修正する. 再発を検出できる検証を加え, 独立した改善は今回の完了条件に含めない.

## Testing

- 目的と影響に応じて検証方法を選び, 正常系, 失敗時の挙動, 関連箇所の回帰を確認する.
- 検証失敗は原因を調べ, 今回の変更によるものは修正する. 無関係な既存問題は切り分けて報告する.
- 成功表示を得るために失敗を隠さない. 仕様変更で不要になったtestは見直し, 未検証の範囲と残るリスクを報告する.

## Version Control

この節はrepository内のfileを変更するtaskに適用する. 回答だけの相談やレビューでは, この節の手続きは不要.

`git` ではなく `jj` を使う. remoteがなければ関連指示は省略.

- localとremoteの状態を確認し, 最新の情報に基づいて作業する. 同期は作業に必要な範囲で, 既存変更を損なわない方法で行う.
- 既存変更は内容と出所を確認し, 今回の変更と分離して保護する. taskに関係しない変更を勝手にcommit, push, 破棄しない.
- 成果は検証後にcommitする. pushは依頼またはrepositoryの運用に含まれ, 内容を公開してよい場合に行う.
- commit messageはConventional Commitsに従い, `<type>[optional scope][!]: <description>` とする.
- 公開先は `main` とする. 他のbookmarkやbranchはtaskに必要な範囲で扱い, 無関係なものは変更しない.
- expgolemclone 以外のuserのrepositoryにpushしない.
- Box上のfileは `git` と `jj` で管理しない.
- private repositoryではGitHub Actionsを使わない.
