# Ordinary variables

Use this route for targeted inspection, creation, replacement, or deletion of ordinary environment variables.

## Inspect

Use exact redacted queries whenever the name is known:

```powershell
envx get NAME --format json
envx get NAME --scope user --format json
```

Use a scoped list only for discovery. Add `--query TEXT`, `--names-only`, or `--limit N` to keep the result narrow:

```powershell
envx list --scope user --format json --query TEXT --limit N
envx list --scope user --names-only --query TEXT --limit N
```

## Set

Compare the exact name across scopes, choose the destination scope, then set it:

```powershell
envx set --scope user NAME VALUE
```

Setting replaces an existing value in that exact scope.

## Delete

`delete` accepts a pattern. Use an exact name by default and `--force` to avoid an interactive prompt after the target
is known:

```powershell
envx delete --scope user NAME --force
```

Use wildcard deletion only when the user requested a matching set and the preceding redacted query established all
affected names.
