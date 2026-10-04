# AGENTS Rules

## General

- 半角記号と `, `, `. ` を使い, Markdownは簡潔にする.
- 一時file/folderは `C:/dev/tmp/reponame-taskname-timestamp` に置き, 完了後に削除する.
- 依頼範囲を完了まで進め, 阻害要因は報告する.
- 目的, 前提, 手段を調べ, 迎合せず判断する. 誤解を疑い, 問題は根拠と代案を示す. 依頼変更が必要なら止めて確認する.

## Tools

- 調査や推論で解決できることはAIが決める. userの判断が必要な点だけ質問し, 数字の選択肢と推奨案1を示す.
- 画像生成と手動GUI操作は行わず, 必要ならuserに依頼する.

## Preparation

- 複数工程の作業は `PLAN.md` にtodoと進捗を書き, 完了後に削除する. 単純な変更や相談では不要.
- repositoryのpathは `$HOME/local-repository-map/RepositoryMap.psm1` をimportし, `Read-LocalRepositoryMap` で調べる.
- 関連する `RULES.md`, `SKILL.md` を読む. installは `expgolemclone/envx/RULES.md` に従う.

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
