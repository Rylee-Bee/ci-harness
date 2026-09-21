# ci-harness

Shared GitHub Actions pipeline machinery for the Rylee-Bee estate:
`workflow_call` reusable workflows plus one single source of truth for
action SHA pins (`pins/ACTIONS.md`). The rule is **adopt the mechanics, own
the semantics** — this repo owns checkout/setup/pinning/sync/artifact
plumbing; each consuming repo keeps a thin contract workflow declaring
*which* checks run and *what they mean*. Repo-owned gates
(public-safety tests, determinism censuses, contrast audits) never move
here: if no template fits a check, it stays a small inline job in the
consumer's own workflow rather than contorting a template.

Adoption looks like this — a ~15-line contract replacing hundreds of lines
of copy-pasted plumbing, keeping the repo's real check arguments:

```yaml
name: validate
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  test:
    uses: Rylee-Bee/ci-harness/.github/workflows/reusable-python.yml@main
    with:
      sync-args: "--extra test --extra crypto"
      pytest-args: "--timeout=30"
```

Available templates:

| Workflow | Shape |
|---|---|
| `reusable-python.yml` | uv + `uv sync --frozen` + repo-given pytest args, optional repo gates after pytest, optional ruff/bandit jobs |
| `reusable-node.yml` | setup-node + `npm ci` + optional build/lint/test + dist artifact upload; optional Python/uv bootstrap for polyglot e2e (Playwright on a uvicorn app) |
| `reusable-container-smoke.yml` | docker build + detached run + configurable healthz curl retry loop, with container logs on failure |

How this repo proves itself (static checks alone prove nothing for
`workflow_call`): `actionlint-selfcheck.yml` lints every workflow here with
a checksum-pinned actionlint, and `self-smoke.yml` **really executes** each
template against the fixtures under `fixtures/` on every push/PR.

Callers reference templates by `@main` for adoption simplicity; repos that
want stronger immutability may pin a ci-harness commit SHA in the `uses:`
line instead — the templates are byte-identical at a SHA.

## Permissions

Caller token permissions flow down and can only be **kept or downgraded**
by a called workflow, never elevated (GitHub validates this before the run
starts). So the templates take their grants from the caller: `reusable-node`
declares no top-level `permissions:` at all — jobs that enable `upload-dist`
must grant `actions: write` at the calling job (or workflow) level; with
`upload-dist: false`, plain `contents: read` is enough. The python and
container templates declare only `contents: read`.

## Visibility requirement

GitHub's access matrix for reusable workflows: **a workflow in a public
repository can only call reusable workflows hosted in public repositories**
([official rule](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#access-to-reusable-workflows)).
An inaccessible private host surfaces as `workflow was not found` at parse
time, with zero jobs scheduled. So adoption from a **public** repo requires
ci-harness to be public; private repos can call it either way.

> **Name disambiguation:** Play-Nice `harness/` is a behavioral-research
> ledger; unrelated name collision. This repo is *CI* machinery only.
