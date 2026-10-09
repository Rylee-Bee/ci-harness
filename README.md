# ci-harness

## What this is

The estate's shared GitHub Actions workflows. A repo that needs CI writes one short
workflow that calls a template here, instead of copy-pasting the same checkout,
setup and version-pinning steps into every repo. One place holds that plumbing, so a
fix to it lands once and every repo that calls the template gets it — at the revision
it pinned, not automatically.

## Is it running?

`UNKNOWN`. A reusable workflow does nothing until a repo calls it, and this repo cannot
see its callers. Prove it with:

    gh search code "Rylee-Bee/ci-harness/.github/workflows" --owner Rylee-Bee

No hits, or only this repo's own `self-smoke.yml`, means nothing is calling them right
now. A merge to this repo's `main` is not a deployment event for anyone.

## How to use it

Pick the template your checks fit, and call it from your repo's workflow pinned to a
commit SHA of this repo:

```yaml
name: validate
on:
  pull_request:
permissions:
  contents: read
jobs:
  test:
    uses: Rylee-Bee/ci-harness/.github/workflows/reusable-python.yml@561b1daa2314f5e902c5b1e4e2a24802a9ecdfaf  # pinned SHA
    with:
      sync-args: "--extra test"
      pytest-args: "--timeout=30"
```

There are eight templates, named for what they run: `python`, `node`,
`container-smoke`, `contract-freshness`, `uat`, `secret-scan`, `claims-policy`,
`project-home`. Each one takes the commands and thresholds that make it yours, and does
the rest.

Reading results: `gh pr checks <pr>` in your repo, `gh run list -R Rylee-Bee/ci-harness`
for this one. Finding every repo you have to re-pin after a template changes: the
`gh search` line above.

Before you adopt: GitHub only lets a public repo call reusable workflows hosted in
public repositories ([rule](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#access-to-reusable-workflows)),
so check this repo's visibility first.

## Where to read more

- [`AGENTS.md`](AGENTS.md) — the map, the template list, permissions, telemetry, and the
  rules for changing any of it.
- [`pins/ACTIONS.md`](pins/ACTIONS.md) — every pinned action SHA and the bump protocol.
- [`.project/CURRENT.md`](.project/CURRENT.md) — this repo's entrypoint.
- [`docs/ACTIONS-COST-DISCIPLINE.md`](docs/ACTIONS-COST-DISCIPLINE.md) — the estate's CI
  cost rule; read it before adding or widening a workflow.