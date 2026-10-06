# ci-harness

**What this repo is:** Shared GitHub Actions pipeline machinery for the Rylee-Bee estate —
`workflow_call` reusable workflows plus the single source of truth for action SHA pins
(`pins/ACTIONS.md`). GitHub remote `Rylee-Bee/ci-harness` is **PUBLIC**.

**Principle — adopt the mechanics, own the semantics.** This repo owns checkout/setup/
pinning/artifact plumbing. Each consuming repo keeps a thin contract workflow declaring
*which* checks run and *what they mean*. Repo-owned gates (public-safety tests, determinism
censuses, contrast audits) never move here; if no template fits, the check stays inline in
the consumer.

Estate rules: `~/.agents/AGENTS.md` and `play-nice-contracts/contracts/everyone/FLOOR.md`.

## Map

| Path | Kind | Purpose | Open it? |
|---|---|---|---|
| `.github/workflows/reusable-*.yml` | source | the seven templates consumers call via `uses:` (python, node, container-smoke, contract-freshness, uat, secret-scan, project-home) | yes, when changing a template |
| `.github/workflows/self-smoke.yml` | source | **real execution** of every template against `fixtures/` | yes, with any template change |
| `.github/workflows/actionlint-selfcheck.yml` | source | static lint of all workflows with checksum-pinned actionlint | rarely |
| `.github/workflows/secret-scan-selfcheck.yml` | source | runs `reusable-secret-scan.yml` on this repo (full history) | rarely |
| `pins/ACTIONS.md` | docs/contract | every pinned action SHA, binary sha256, toolchain default, and the bump protocol | yes, before touching any `uses:` SHA or version default |
| `README.md` | docs | adoption guide, template table, permissions + visibility rules, freshness semantics | yes; keep in sync with template inputs |
| `fixtures/*-demo/` | fixtures | minimal projects self-smoke drives (py, node, container, uat, contract) | when the matching template changes |
| `fixtures/contract-demo/current-adoption.yaml` | fixture | CURRENT pin; moved by the Play-Nice pin robot (`chore(play-nice): pin …` PRs) | don't hand-edit |
| `fixtures/contract-demo/stale-adoption.yaml` | fixture | permanently stale pin; MUST stay red | never "fix" it |

Lockfiles (`fixtures/*/uv.lock`, `package-lock.json`) are committed on purpose so
`uv sync --frozen` / `npm ci` have something real to install.

## Commands

There is no local build, test runner, or lint wrapper, and `actionlint` is not installed on
the workstation. **CI is the gate**, on every push to `main` and every PR:

- `actionlint-selfcheck` — `./actionlint -color` over `.github/workflows/*.yml`
- `self-smoke` — calls each template through its real `uses:` contract
- `secret-scan-selfcheck` — gitleaks over full history

Optional local sanity for a fixture (same invocations the templates run):

- `cd fixtures/py-demo && uv sync --frozen --extra test && uv run pytest --timeout=30 -q`
- `cd fixtures/node-demo && npm ci && npm run build && npm run lint`

Read CI results with `gh run list -R Rylee-Bee/ci-harness` or `gh pr checks <n>`.

## Boundaries

- **Consumers call templates at a pinned SHA.** This was once documented as `@main`; it
  never was, in practice. Measured 2026-10-06 across the 40 `Rylee-Bee` repos: **28**
  workflow files reference these templates at **5 distinct commit SHAs** (12 distinct
  `workflow@revision` pins), spanning 2026-09-29 → 2026-10-05. The only `@main` reference
  in the estate is this repo's own `self-smoke.yml`, which is a legitimate self-test.
  **A merge to `main` is therefore not a deployment event for anyone** — consumers keep
  running the revision they pinned until they re-pin. Before a breaking change, find every
  pinned consumer:
  `gh search code "Rylee-Bee/ci-harness/.github/workflows" --owner Rylee-Bee`
  and expect to move pins deliberately, not automatically.
- Template inputs/outputs/secrets are a public interface: add inputs with safe defaults;
  renaming or removing one is breaking — record the consumer companion edits, don't make
  them (sibling repos need explicit authorization).
- Permissions flow caller → template and can only be downgraded. `reusable-node` and
  `reusable-uat` declare no top-level `permissions:`; see README "Permissions" before
  adding any grant.
- Contract freshness clones `play-nice-contracts` at tip, **deliberately unpinned**; the
  verdict comes from `contractctl` there. There is no sync job here and never will be.
- Name collision: Play-Nice `harness/` is an unrelated research ledger.

## Needs Rylee's approval here

- Bumping or changing any pin in `pins/ACTIONS.md` (propagates to every consumer).
- Breaking template interface changes, or loosening a fail-closed gate
  (`expect:` semantics, the stale probe, the actionlint checksum).
- Changing repo visibility (public is required for public consumers — README "Visibility").
- General gates: see the constitution.

## Working defaults

- **Public repo:** no LAN IPs, hostnames, home paths, tokens, or private-repo internals in
  any file, commit message, or fixture. Secrets reach templates only as `secrets:` inputs.
- Every `uses:` of an external action is a 40-char SHA with a `# vX.Y.Z` comment, matching
  `pins/ACTIONS.md`. Bump = table + every workflow occurrence in **one commit**, SHA resolved
  with `git ls-remote … refs/tags/<tag>^{}` (never copied from another repo).
- A new or changed template input gets a self-smoke job exercising it — static lint alone
  proves nothing for `workflow_call`. Prove red paths as positive assertions (GitHub forbids
  `continue-on-error` on `uses:` jobs; follow the `expect: noncurrent` pattern).
- Extend an existing template before adding a new one; update README's template table in
  the same change.
- Other worktrees of this repo may exist; check `git worktree list`.

## Done means

A PR whose `actionlint-selfcheck`, `self-smoke`, and `secret-scan-selfcheck` runs are green
(cite `gh pr checks`), README / `pins/ACTIONS.md` updated where the change touches them, and,
for interface changes, the consumer companion edits listed. Merged to `main` is live for
consumers; there is no separate deploy.

## Handoff

No repo-local handoff directory. Session state goes to Project Home (estate `AGENTS.md` §4).
