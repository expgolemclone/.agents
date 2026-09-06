# Diagnosis and recovery

Use this route for safe diagnosis, malformed-name repair, and encrypted backup recovery.

## Diagnose

Run `doctor` independently for each relevant exact scope:

```powershell
envx doctor --scope user
```

It reports invalid-name counts and PATH health without revealing values.

## Repair invalid names

`repair invalid-names` is a preview until `--apply` is added:

```powershell
envx repair invalid-names --scope user
envx repair invalid-names --scope user --apply
```

Do not reconstruct or print malformed names from any embedded value.

## Restore an encrypted backup

List available backup IDs without revealing payloads:

```powershell
envx backup list
```

Restore only an exact ID supplied by the user, printed by a preceding mutation, or uniquely established by the task.
Never choose a backup by recency alone when more than one ID is plausible. Restore has no preview and requires apply:

```powershell
envx backup restore BACKUP_ID --apply
```

The restore creates a backup of the state it replaces.
