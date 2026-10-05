# Pi agent resources

- `AGENTS.md`: global Pi instructions.
- `settings.json`: provider, model, thinking level and OpenAI service tier. The `.pi` extension reads this file directly.
- `skills/`: Agent Skills discovered by Pi.
- `skills-manager/`: synchronizes external skills from GitHub.
- `workflow/`: shared jj task helpers. Import `workflow/AgentWorkflow.psm1` and run `Get-AgentWorkflowHelp`; do not read implementation unless troubleshooting.

## Workflow

Task directories use `C:/dev/tmp/<owner>--<repo>--<task>--<id>/`, e.g. `expgolemclone--.agents--fix-widget--a1b2c3d4`. Preserve mapped owner/repo names, use a short task slug and an 8-digit random hexadecimal ID, not a commit hash. Task IDs and handoff branch names are unchanged.

```powershell
Import-Module "$HOME/.agents/workflow/AgentWorkflow.psm1"
Get-AgentWorkflowHelp
$t = Start-AgentTask -Repository expgolemclone/example -Name fix-widget -Execute
Set-Location $t.Repository
# Edit/test here. Put PLAN.md beside repository/, not inside it.
Complete-AgentTask -TaskDirectory $t.TaskDirectory -Message 'fix: widget' -Test {
    npm test
    if ($LASTEXITCODE -ne 0) { throw 'npm test failed' }
}
Remove-AgentTask -TaskDirectory $t.TaskDirectory
```

Omit `-Execute` for planning; `continue` is not `doit`. Research files are allowed, but commits, pushes and claims are not. Use `Enable-AgentTaskExecution -TaskDirectory <task> -Doit` only after authorization.

For handoff, write remaining todos, blockers and next steps in PLAN.md, then `Publish-AgentHandoff`. Only this explicit handoff publishes code and PLAN to `handoff/<task-id>`. Unfinished conflicts are allowed on handoff branches only. Successful ordinary tasks publish no plan.

`Get-AgentHandoff` returns unowned IDs only. Use `Receive-AgentHandoff -TaskDirectory <fresh-authorized-task> -TaskId <id>` to claim before reading the returned PLAN. Each session uses its own clone and claim token. Edit the claimed `.handoff/PLAN.md` body, not its header; if integration fails, edit PLAN.md beside repository/ instead. `Unlock-AgentHandoff` publishes progress and releases ownership. No process monitoring or automatic crash recovery.

Completion creates a code-only change on current main, tests it, pushes forward, deletes the owned handoff branch, and synchronizes the mapped checkout under a lock. Tests run from the clone root, must throw on failure, and must not change tracked files. Up to three main-update races are retried; claim races are never retried automatically. Pushes to other GitHub owners are refused.

Failures retain the task and test log. Resolve the cause and retry completion; already-pushed code is not pushed again. A dirty mapped checkout stops synchronization without undoing main publication. Every registered workspace must be published, or empty with all parents published. Synchronization moves only the mapped workspace; other workspace targets stay unchanged. `Sync-AgentRepository` retries synchronization alone. Do not edit a clone after successful publication. Cleanup accepts only completed managed tmp directories and rejects links. For completed plan-phase research, use `Remove-AgentTask -ResearchComplete` without publishing.

Integration tests, with local remotes only: `pwsh -NoProfile -File workflow/tests/AgentWorkflow.Tests.ps1`.

Pi authentication, history, UI and project trust remain in `~/.pi`. These settings do not provide sandboxing.
