# Skills Manager

GitHub上の外部Agent Skillを, 同じ `.agents` repo内の `skills` folderへ同期するmanagerです.

## Files

- `skills-updater.py`: update確認と同期を行うCLI.
- `skills-updater.json`: 同期対象と取得元を管理する唯一の設定.
- `skills-updater.lock.json`: 解決したcommitとcontent hashを記録する自動生成file.
- `tests/`: 設定検証, archive展開, transaction rollbackのtest.

source一覧は `skills-updater.json` のみに置き, このREADMEへ転記しません. Scheduled Taskのscheduleと実行actionは `task-scheduler-management` repoのみで管理します.

## Usage

`skills-manager` folderで実行します.

```powershell
python .\skills-updater.py --check
python .\skills-updater.py
```

`--check` はfileを更新せず, updateの有無だけを返します. 同期実行は設定対象だけを置換し, lock fileを同じtransactionで更新します.

## Test

```powershell
python -m unittest discover -s .\tests -v
```
