---
{"schema":1,"taskId":"move-smec-skill-20261009-000013-308-ed7eee25","base":"be2b98bdadfcfdc9d0f4e5c72f2c48e9d57e0b6e","phase":"execute","owner":null}
---
# Move smec-quality to its owner on NucBox

Explicit user choice: preserve the skill by moving it to smec-second, not retire it.
Company must not clone, build, test, run or resume smec-second. No destination work has been performed.

## Receive on NucBox

1. Import ~/.agents/workflow/AgentWorkflow.psm1 and use Get-AgentWorkflowHelp.
2. Resolve current RepositoryMap and require NucBox. Start a fresh .agents task with -Execute, list available handoffs, then Receive-AgentHandoff for this task ID. Read the claimed PLAN only after ownership.
3. Start a separate fresh expgolemclone/smec-second task from latest main. Read its RULES.md and referenced quality contracts. Do not preserve unknown bookmarks without explicit approval.
4. Move the claimed .agents skills/smec-quality/SKILL.md into smec-second/skills/smec-quality/SKILL.md. Keep its safety/ownership rules. Add or merge .pi/settings.json skills:[../skills] so one canonical skill is advertised. Fix relative paths if necessary.
5. Run smec-second's actual required tests and installed Pi skill discovery on NucBox. Publish and synchronize its mapped main first.
6. Only after verified destination publication/synchronization, remove the global .agents skill in the claimed .agents task. Run the full skills-manager Python suite and verify the remaining four common skills plus globally referenced envx have no collisions. Complete-AgentTask publishes .agents, synchronizes NucBox and removes the owned handoff bookmark.
7. Synchronize company .agents and validate company source scope later; do not claim this migration alone makes company E2E pass.

## Related work already published

- .agents main be2b98bdadfcfdc9d0f4e5c72f2c48e9d57e0b6e removed divergent global envx only and added ownership rules.
- Pi setup references envx/skills/envx from current-PC RepositoryMap. Trust stays always.
- Garoon, SMTP and Task Scheduler project discovery is published and synchronized.

## Company blockers

- Three unrelated unfinished update-skills task areas still contain smec-quality: 1bcb9b62, 99945890, d5ba95e4. Their plans have not been read or claimed. Do not rescue or bulk-delete them.
- Kintone no-remote checkout migration is prepared locally but unapplied: shared synchronization lock timed out twice (60s and 120s). Current registered files remain clean and unchanged.
- Autohotkey ZIP adaptation is in a separate explicit handoff because full company suite fails the source prohibition. Its 112 Python tests and all AutoHotkey checks passed.
- The existing Codex inventory removal task is still blocked on required company source E2E; no inventory workaround is authorized.
