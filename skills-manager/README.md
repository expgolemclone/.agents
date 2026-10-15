# Skills Manager

This manager synchronizes external Agent Skills from GitHub into the `skills` folder in the same `.agents` repository.

Configure sources in `skills-updater.json`. Scheduled execution is managed in `task-scheduler-management`.

## Usage

Run from the `skills-manager` folder.

```powershell
python .\skills-updater.py --check
python .\skills-updater.py
```

`--check` reports whether updates are available without modifying files. Synchronization replaces only configured targets and updates the lock file in the same transaction.

## Test

```powershell
python -m unittest discover -s .\tests -v
```
