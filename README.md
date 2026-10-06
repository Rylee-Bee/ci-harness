# ci-harness

Shared GitHub Actions pipeline machinery for the Rylee-Bee estate:

> **Cost discipline:** private-repo CI should preserve proof while folding duplicate billing. Before adding or expanding a workflow, read [docs/ACTIONS-COST-DISCIPLINE.md](docs/ACTIONS-COST-DISCIPLINE.md).
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
| `reusable-contract-freshness.yml` | shallow-clone the Play-Nice contract source over https, run `contractctl freshness --manifest <caller manifest> --json`; exit 0 only on CURRENT (fail closed) |
| `reusable-uat.yml` | pinned checkout + setup-node (npm cache, conditional `npm ci`) + a caller-supplied real-browser UAT command under a `UAT_READONLY=1` read-only posture with optional `uat-token` passthrough; UAT output uploaded as an artifact (14-day retention) |
| `reusable-secret-scan.yml` | pinned checkout + pinned gitleaks-action secret scan; a repo-local `.gitleaks.toml` allowlists documented false positives instead of suppressing at the harness level. `fetch-depth` defaults to 1 (fast PR check); use 0 for a full-history scan |
| `reusable-project-home.yml` | narrow Project Home CI reporter: exact task claim/heartbeat/finish plus deduplicated BOOP notice, each call carrying W3C trace context; callers pass the private base URL and a dedicated `ci`-scope token only as secrets |

How this repo proves itself (static checks alone prove nothing for
`workflow_call`): `actionlint-selfcheck.yml` lints every workflow here with
a checksum-pinned actionlint, and `self-smoke.yml` **really executes** each
template against the fixtures under `fixtures/` on every push/PR.

## Telemetry

Every template emits one OpenTelemetry pipeline span and one job span per job,
following the estate telemetry contract: OTLP over HTTP as JSON, W3C trace
context, and the standard CI/CD and VCS semantic conventions (`cicd.*`, `vcs.*`)
with estate attributes only where no standard name carries the meaning
(`estate.host.class`, `estate.actor.kind`, `estate.mission.id`, `estate.task.id`).

It is a **side effect and nothing else**:

- Off by default. Telemetry runs only when the caller sets
  `vars.OTEL_EXPORTER_OTLP_ENDPOINT`; unset, every telemetry step is skipped and
  the workflow behaves exactly as it does today.
- A GitHub-hosted runner cannot reach the LAN Collector, so it logs
  `skipped: GitHub-hosted runner cannot reach the LAN Collector` and carries on.
- Every telemetry step is `continue-on-error`, and the closing step runs with
  `if: always()` so a failed job still reports what it was doing. A span can
  never turn a pipeline red or green.
- Nothing private leaves: no secrets, tokens, runner names, host names, IPs,
  file contents or paths. `estate.host.class` is a declared class
  (`dev-vm`, `bazzite`, `dockerhost`, `stack-vm`, `github-hosted`, `unknown`),
  not a hostname — declare it with the `host-class` input or `ESTATE_HOST_CLASS`.

A pull request a mission lands carries an `Estate-Task: <mission_id>/<task_id>`
commit trailer; the reporter reads it and joins the mission task's trace, which
any producer can compute from the same ids (see `scripts/otel-span.sh`). A
pull request without one gets its own trace, correlated by `vcs.change.id` —
expected, not an error. The Project Home reporter attaches the resolved
`traceparent` to claim, heartbeat, finish and notice; a caller that already has
context passes it through the `traceparent` input.

The emitter is `scripts/otel-span.sh` — bash, curl and sha256sum, no new action
dependency and nothing to install. Its own self-test is the proof that needs no
GitHub:

```sh
bash -n scripts/otel-span.sh && bash scripts/otel-span.sh --self-test
```

Callers reference templates by `@main` for adoption simplicity; repos that
want stronger immutability may pin a ci-harness commit SHA in the `uses:`
line instead — the templates are byte-identical at a SHA.

## Project Home orchestration

The reporter deliberately carries no approval authority. Project Home remains the
task, approval, lease, and BOOP source of truth; CI gets a dedicated `ci` bearer
scope and may only operate through the narrow `/api/ci/*` surface.

A caller typically claims a Project Home task before its real job and reports the
final outcome afterward. The URL and token stay repository secrets, so this public
harness never records private topology:

```yaml
jobs:
  claim:
    uses: Rylee-Bee/ci-harness/.github/workflows/reusable-project-home.yml@main
    with:
      action: claim
      task-id: "123"
    secrets:
      project-home-url: ${{ secrets.PROJECT_HOME_URL }}
      project-home-token: ${{ secrets.PROJECT_HOME_CI_TOKEN }}

  # ...repo-owned work...

  finish:
    uses: Rylee-Bee/ci-harness/.github/workflows/reusable-project-home.yml@main
    with:
      action: finish
      task-id: "123"
      outcome: succeeded
      note: "tests and smoke checks passed"
    secrets:
      project-home-url: ${{ secrets.PROJECT_HOME_URL }}
      project-home-token: ${{ secrets.PROJECT_HOME_CI_TOKEN }}
```

The default actor is stable for the workflow run (`gha:<repo>:<run_id>`), so
separate claim/finish jobs in the same run share one lease identity. Responses
are written to a temporary file and never echoed; logs expose only the action and
HTTP status.

## Contract freshness

Repos that pin a Play-Nice contracts revision (an adoption-v1 manifest with
`source.revision`) call one ~4-line job to detect drift — the one question
it answers is *has the authoritative remote moved past our pin?* — typically
on a weekly schedule and whenever the manifest itself changes:

```yaml
  contract-freshness:
    uses: Rylee-Bee/ci-harness/.github/workflows/reusable-contract-freshness.yml@main
    with:
      manifest-path: .project/contracts/adoption.yaml
```

Mechanics are fail-closed by construction: the job runs
`contractctl freshness --json` from a fresh shallow clone of
`Rylee-Bee/play-nice-contracts` and propagates its exit code — 0 **only**
when the verdict is CURRENT; BEHIND/DIVERGED exit 1; UNREACHABLE/UNKNOWN
(missing or malformed manifest included) exit 2. The tool's JSON verdict is
printed, and `exit-code` / `status` are exposed as job outputs so a caller
can assert on the verdict without parsing logs. The default `expect: current`
input means red on ANY drift; `expect: warn` (for pull requests in a repo
whose pin moves by robot, `tools/pin-sync` in play-nice-contracts) passes with
a visible warning and keeps the real verdict in `status`;
`expect: noncurrent` is the harness's own
self-smoke inversion (see below) and is not a soft-fail knob.

**Detection is automated; pin movement is manual.** A red freshness job
means: read what changed upstream (verify commit + VERSION/CHANGELOG + lock
diff, re-read, re-attest), then re-pin `source.revision` in the consumer
repo as a human-reviewed commit — or accept the lag knowingly. There is
deliberately no sync job here, and there never will be.

self-smoke proves both verdicts as POSITIVE assertions on every run: the
committed current-pin fixture must pass through the real `uses:` call; a
permanently stale fixture must exit nonzero — proven by an inversion job
(`expect: noncurrent`, green exactly when the gate correctly goes red,
because GitHub forbids `continue-on-error` on `uses:` jobs) plus an
assertion job on the probe's propagated outputs; and a manifest generated
live from `git ls-remote` at run time must read CURRENT, so the green-path
witness never rots when the library moves. When upstream does advance, the
committed current-pin fixture goes red on purpose until a human re-pins it.

## Permissions

Caller token permissions flow down and can only be **kept or downgraded**
by a called workflow, never elevated (GitHub validates this before the run
starts). So the templates take their grants from the caller: `reusable-node`
and `reusable-uat` declare no top-level `permissions:` at all because they
upload artifacts — jobs that enable `upload-dist` (node) or
`upload-artifacts: true` (uat) must grant `actions: write` at the calling
job (or workflow) level; with those upload inputs false, plain
`contents: read` is enough. The python and container templates declare only
`contents: read`.

## Visibility requirement

GitHub's access matrix for reusable workflows: **a workflow in a public
repository can only call reusable workflows hosted in public repositories**
([official rule](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#access-to-reusable-workflows)).
An inaccessible private host surfaces as `workflow was not found` at parse
time, with zero jobs scheduled. So adoption from a **public** repo requires
ci-harness to be public; private repos can call it either way.

> **Name disambiguation:** Play-Nice `harness/` is a behavioral-research
> ledger; unrelated name collision. This repo is *CI* machinery only.
