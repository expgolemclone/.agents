# File import and export

Use this route for scoped transfer between envx and `.env`, JSON, YAML, text, PowerShell, or shell files. Select the
format from a supported extension, or pass `--format` when the extension is absent or ambiguous.

## Import

`import` provides a redacted preview with `--dry-run`:

```powershell
envx import FILE --scope user --dry-run
envx import FILE --scope user
```

Use repeated `--vars PATTERN` options to limit the import and `--prefix PREFIX` only when requested. Use `--overwrite`
only for requested replacements after the dry run reports conflicts.

## Export

Export has no preview and writes plaintext values. Resolve each requested pattern before exporting it:

```powershell
envx get PATTERN --scope user --format json
envx export FILE --scope user --vars PATTERN
```

When the request intentionally covers the entire selected scope, inspect all selected names and omit `--vars`:

```powershell
envx list --scope user --names-only
envx export FILE --scope user
```

Do not add `--force` unless replacing the exact destination is required. Report the destination and exported count
without printing file contents.
