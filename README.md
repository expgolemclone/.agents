# Shared agent resources

- `AGENTS.md`: global rules shared by Codex and Pi.
- `settings.json`: the source for model, reasoning effort, service tier, approval policy and sandbox mode.
- `skills/`: shared Agent Skills, discovered by both applications.
- Codex: run `uv run --no-project python ~/.codex/scripts/sync_config.py` after updating this repository. It generates Codex's local configuration and global instructions, retaining local project trust and TUI state.
- Pi: reads these files directly through the extension in the `.pi` repository. It needs no `.codex` directory.
- Application-specific UI, authentication, history and project trust stay in each application's directory. These shared files do not provide cross-application sandboxing.
