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

- ECRSの順に, 目的を満たす単純で一貫した設計を選ぶ. 既存構成や互換性に固執しない.
- 正本と責務を明確にする. 複製, fallback, overrideは効果と複雑さで判断し, 不整合や失敗を隠さない.
- 根本原因と必要な関連箇所を修正し, 再発を検証する. 無関係な改善は別taskとする.

## Testing

- 変更の影響に応じて検証する. 変更による失敗は直し, 無関係な失敗, 未検証範囲, 残るリスクは報告する. 成功表示のために失敗を隠さない.

## Version Control

- file変更時は `jj` で最新状態を確認し, 既存変更や無関係なbookmarkを保護する. 相談だけなら不要.
- 検証後にConventional Commitsでcommitする.
- pushは依頼や運用に必要で公開可能な成果だけを, expgolemcloneのrepositoryの `main` へ送る.
- Box上のfileは `git` と `jj` で管理しない.
- private repositoryではGitHub Actionsを使わない.
