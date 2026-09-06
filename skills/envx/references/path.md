# PATH variables

Use this route for `PATH` or another path-list variable selected with `--var NAME`. Every command requires one exact
scope.

## Inspect

Use these commands to inspect and validate the path list:

```powershell
envx path --scope user list --numbered --check
envx path --scope user check --verbose
```

Resolve a move from the numbered list. Preserve the stored path text even when envx shows an expanded path during
validation.

## Mutate

PATH mutations are previews until `--apply` is added:

```powershell
envx path --scope user add 'C:\Tools'
envx path --scope user remove 'C:\Tools' --all
envx path --scope user move FROM TO
envx path --scope user dedupe --keep-first
envx path --scope user clean --dedupe
```

Use `--first` only when ordering requires the new directory to win command resolution. Use `--create` only when creating
a missing directory is part of the requested end state. Prefer `--keep-first` for duplicate cleanup because earlier PATH
entries control command resolution.
