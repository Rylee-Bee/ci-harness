# ci-harness

**What this repo is:** Shared GitHub Actions pipeline machinery for the Rylee-Bee estate —
`workflow_call` reusable workflows and a single source of truth for action SHA pins
(`pins/ACTIONS.md`). Public GitHub remote: `Rylee-Bee/ci-harness`.

## Principle

**Adopt the mechanics, own the semantics.** This repo owns checkout/setup/pinning/sync/artifact
plumbing. Each consuming repo keeps a thin contract workflow declaring *which* checks run and
*what they mean*. Repo-owned gates never move here.

## Key files

| File | Purpose |
|---|---|
| `pins/ACTIONS.md` | Canonical action SHA pins — single source of truth |
| `README.md` | Adoption guide with example workflow |
| `.github/workflows/` | The reusable workflows themselves |

## Boundaries

- Do not add repo-specific business logic (public-safety checks, contrast audits) to shared templates.
- Pin changes are the most impactful edits here — they propagate to all consumers. Verify intent before bumping.
- No worktrees in active use (verify with `git worktree list`).
