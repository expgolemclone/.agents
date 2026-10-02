# Pi agent resources

- `AGENTS.md`: global Pi instructions.
- `settings.json`: provider, model, thinking level and OpenAI service tier. The `.pi` extension reads this file directly.
- `skills/`: Agent Skills discovered by Pi.
- `skills-manager/`: synchronizes external skills from GitHub.

Pi authentication, history, UI and project trust remain in `~/.pi`. These settings do not provide sandboxing.
