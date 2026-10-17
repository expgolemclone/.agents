# AGENTS Rules

## General

- User instructions and repository-specific rules take precedence over this file when they conflict.
- Use English.
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

- Read `$HOME/.agents/RULES.md` and the relevant `RULES.md` and `SKILL.md` files.

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

- Apply ECRS: Eliminate, Combine, Rearrange, Simplify.
- Group related files into folders.
- Duplicate management, duplicate implementations, inconsistent terminology, fallbacks, and overrides are prohibited.
- Do not add documentation. Cut it.

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

- Follow `$HOME/.agents/workflow/HANDOFF.md` for bookmark restrictions and handoff.

## Constraints

- Do not push to repositories outside expgolemclone.
  For repositories without a remote, work serially at the registered path.

- Do not use git or jj on Box.
  Do not use GitHub Actions for private repositories.
