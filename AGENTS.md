# AGENTS Rules

## General

- User instructions and repository-specific rules take precedence over this file when they conflict.
- use English for context reasons.
- Quote `@` in PowerShell commands.

- Full-width punctuation is prohibited.
  Use `, ` and `. ` for punctuation.
- Image generation and manual GUI interaction are prohibited.

- When the user enters `plan`, only investigate and propose until they enter `do`.
  - Creating research materials and running verification in the task directory are allowed.
  - Do not implement, make operational changes, commit, or push.
  - Do not stop until all items in `PLAN.md` are complete.
    - If blockers prevent completion, do what is possible and report them.

## Preparation

- Identify the target using `Read-LocalRepositoryMap` from
  `$HOME/local-repository-map/RepositoryMap.psm1`.

- Read the relevant `RULES.md` and `SKILL.md` files.
  - Shared skills belong in `$HOME/.agents/skills/`.
    Repository-specific skills belong in the target repository.

- Follow `expgolemclone/envx/RULES.md` regardless of programming language.

## Design

### Critical

- Before deciding on an approach, always consider whether the user's instructions may be inefficient.
  - What is the official guidance?
  - Is there a better approach than the user's proposal?
  - Minimize custom implementations. Can open-source software be used?

What matters is achieving the goal, not reasoning exactly as the user instructed.

### Simple

> We're against complexity. We believe designing systems is a fight against complexity.
> We'll accept to fight the complexity when it's worthwhile but we'll try hard to recognize when a small feature is not worth 1000s of lines of code.
> Most of the time the best way to fight complexity is by not creating it at all.

- Duplicate management, duplicate implementations, inconsistent terminology, fallbacks, and overrides are prohibited.
- Keep documentation as short as possible. Remove redundancy and link to authoritative sources instead of repeating them.
- Do not duplicate code specifications in documentation. Add such documentation only when explicitly requested.

- Do not cling to backward compatibility. Delete first.
  - Do not preserve the existing design through minimal changes. Tear it down if that makes the system simpler.
  - Apply essentialism. Never keep something merely because it already exists. Ask: If rebuilding from scratch, would you add it again?

## Review

- Focus on whether the overall structure is elegant, rather than on minor errors.
- Review the whole system, not just the latest commit.

## Testing

- When tests fail, fix the root cause and similar problems to prevent recurrence.
  Do not bypass failures with skips or force options.

## Workflow

- Use jj instead of git, and follow Conventional Commits.

- Import `$HOME/.agents/workflow/AgentWorkflow.psm1`
  and follow `Get-AgentWorkflowHelp`.
  Read the code in `workflow/` only when investigating problems.

- When the user enters `handoff`, regardless of whether they have entered `do`, publish the current code and updated PLAN through the workflow, release ownership, and report the task ID.

## Constraints

- The only permitted local and remote bookmarks are `main` and `handoff/*` for unfinished tasks.
  Ask before changing any others.

- Do not push to repositories outside expgolemclone.
  For repositories without a remote, work serially at the registered path.

- Do not use git or jj on Box.
  Do not use GitHub Actions for private repositories.
