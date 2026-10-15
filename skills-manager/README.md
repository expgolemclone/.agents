# Skills Manager

This manager synchronizes external Agent Skills from GitHub into the `skills` folder in the same `.agents` repository.

## Files

- `skills-updater.py`: CLI for checking for updates and synchronizing skills.
- `skills-updater.json`: The sole configuration for synchronization targets and their sources.
- `skills-updater.lock.json`: Automatically generated file recording resolved commits and content hashes.
- `tests/`: Tests for configuration validation, archive extraction, and transaction rollback.

Keep the source list only in `skills-updater.json`; do not duplicate it in this README. Scheduled Task schedules and execution actions are managed only in the `task-scheduler-management` repository.

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
