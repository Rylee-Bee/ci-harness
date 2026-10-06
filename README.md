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
| `reusable-project-home.yml` | narrow Project Home CI reporter: exact task claim/heartbeat/finish plus deduplicated BOOP notice; callers pass the private base URL and a dedicated `ci`-scope token only as secrets |

How this repo proves itself (static checks alone prove nothing for
`workflow_call`): `actionlint-selfcheck.yml` lints every workflow here with
a checksum-pinned actionlint, and `self-smoke.yml` **really executes** each
template against the fixtures under `fixtures/` on every push/PR.

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

## Telemetry

Every template emits a **pipeline span and a job span** per job through
`scripts/otel-span.sh` (ci-harness #19; the contract it follows is homelab's
`docs/observability/TELEMETRY-CONTRACT.md`, homelab #229). **OpenTelemetry observes the estate; it never
becomes the estate.** The GitHub check is still the gate — no step, script or
backend reads these spans to decide whether work passed, approved, or may land,
and a span cannot fail a job.

What a run emits, using OpenTelemetry's own conventions rather than
estate-specific names:

| Attribute | On |
|---|---|
| `cicd.pipeline.name`, `cicd.pipeline.run.id`, `cicd.pipeline.result`, `cicd.worker.name` | every span |
| `cicd.pipeline.task.name`, `cicd.pipeline.task.run.id`, `cicd.pipeline.task.run.result` | job span |
| `vcs.repository.name`, `vcs.ref.head.name`, `vcs.ref.head.revision`, `vcs.change.id` | every span |
| `estate.host.class`, `estate.actor.kind`, `estate.mission.id`, `estate.task.id` | every span |
| `service.name`, `service.namespace=estate` (resource), `http.*`, `url.path` | resource / the Project Home call |

Turning it on is one repository variable, read by every template:

| Variable | Meaning |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | base URL of the Collector; `/v1/traces` is appended |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | per-signal override, wins over the base URL |
| `OTEL_SERVICE_NAME` | defaults to `ci-harness` |
| `ESTATE_HOST_CLASS` | refines the label-derived host class — it never overrides a runner label that says `github-hosted`, because one repository-variable edit must not be able to point a hosted runner at a LAN Collector it cannot reach |

These are the **standard** OTEL environment variables, not an estate-specific
discovery mechanism. There is deliberately **no `workflow_call` input** for the
endpoint: a new input costs a self-smoke job per template (AGENTS.md) for one
string, and this repo's own cost discipline says fold jobs that prove the same
thing. The trade-off is that a consumer cannot point one call at a different
Collector — which matches the estate, where there is one Collector, and keeps
rollback to a single unset.

**Unset endpoint means off**, and the helper then does nothing differently: one
POST per span, a 2-second timeout, no retries, every error swallowed, and a
circuit breaker so an unreachable Collector costs one timeout per job rather
than one per span. Both telemetry steps are `continue-on-error: true`, and the
closing step is `if: always()`, so a failed or skipped job is still recorded
honestly. A `github-hosted` runner cannot reach the LAN Collector, so it emits
nothing at all and says so in the step summary rather than posting a span that
cannot arrive.

**Joining a mission's trace.** A PR a mission lands carries
`Estate-Task: <mission_id>/<task_id>` on its commits; the context step reads it
off HEAD and derives the trace from the ids alone
(`sha256("estate-task|<mission>|<task>")`, first 32 hex) with no shared state.
A PR without the trailer gets its own trace, linked back by `vcs.change.id`.
The Project Home reporter sends the resulting `traceparent` on its `/api/ci`
call, which is how Project Home's own spans land in the same trace — and the
claim, heartbeat and finish calls carry the two ids as an `Estate-Task` request
header, read from that same context, so Project Home's `ci.task.*` spans are
still joinable after the trace is gone: a mission runs for days and no one trace
spans it. That header is the **only** interface: it is the one Project Home
already accepts (`app/projecthome/telemetry.py`, `ESTATE_TASK_HEADER`), and the
reporter deliberately grows no `mission_id` / `mission_task_id` body pair for
existing callers to learn — a CI consumer that knows nothing about telemetry
must see a body it recognises. With no trailer **no header is sent** — no empty
value, no repo-name or run-id stand-in — and a notice, which belongs to no task,
never carries one either.

Two self-smoke jobs prove this without a Collector: `otel-selftest` runs
`scripts/otel-span.sh --self-test` (a throwaway OTLP receiver on 127.0.0.1,
asserting the bodies it captures), and `otel-template-wiring` checks that every
template still carries the pair and runs one template's two steps end to end
against a live receiver.

Because a reusable workflow's `github` context is the **caller's** repository,
`scripts/otel-span.sh` is not present after a template's own `checkout`. Each
template prefers the checked-out tree (self-smoke, where ci-harness *is* the
caller) and otherwise fetches it from ci-harness `@main` — the same reference
policy the templates themselves are adopted under. See
[pins/ACTIONS.md](pins/ACTIONS.md).

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
