Research only. Do not migrate estate CI.

# Dagger vs ci-harness reusable workflows

Study date: 2026-10-06. Repository under study: `Rylee-Bee/ci-harness`, this
clone, branch `offload/arch-t4-dagger-20261006-070457-8658`, HEAD
`aa30fbeafdb022128fce119a10b9008a7d466b94` ("feat: add reusable Project Home
orchestration reporter (#16)", 2026-10-05 13:14:28 -0500). That HEAD is the
commit this study read; every repo-relative path below is as of that commit.

## Summary

Dagger's Python SDK does compress the duplicated checkout/setup-python/uv-sync
block inside `reusable-python.yml` from three copies to one function, so the
"technology works" bar is met. But the compression is roughly four lines: the
YAML's job bodies are 67 lines against 74 lines of input declarations, and the
prototype module is 77 lines, so nothing is actually deleted — the work moves
into a different file while the input surface stays the same size. The
remaining GitHub Actions wrapper, action-pinning contract, `permissions` flow
and secret handling all survive unchanged, so Dagger adds an engine dependency
without removing any ci-harness concept. Dagger Cloud and the documented OTLP
surface are metrics-and-cgroup, not pipeline traces to an estate collector, so
the advertised end-to-end tracing is either an observability island or
unverified here. Dagger's own docs ship at `1.0-beta`, and the shipped
`v0.21.10` CLI does not implement the `dagger settings` / `dagger workspace` /
`dagger sdk` / `dagger list` commands its own documentation tells you to run.
Nothing meaningful becomes smaller or disappears. **REJECT**.

## The rule this study answers

Rylee, 2026-10-06, quoted verbatim:

> The success criterion is not 'the product works.' Their success criterion is:
> What existing estate machinery becomes simpler, standardized, smaller, or
> unnecessary? If a technology adds another service but removes no meaningful
> complexity, recommend rejection.

and:

> The preferred result is fewer concepts and less custom plumbing. A successful
> evaluation may conclude that the technology should not be adopted. If nothing
> meaningful becomes simpler or disappears, default toward rejection.

The decision rule from the issue, quoted verbatim:

> Recommend adoption only if Dagger lets us delete or substantially simplify
> real ci-harness workflow and script logic. If the result is GitHub YAML calls
> Dagger which calls all the same scripts, reject it.

The boundary preserved throughout: ci-harness owns shared CI and golden paths
and the narrow Project Home reporting boundary. GitHub Actions may remain the
trigger and orchestrator even if execution moves. Project Home remains the task
and approval authority. Dagger must never gain approval authority — no part of
this study proposes giving it any.

## Which workflow you picked and why

I picked **`.github/workflows/reusable-python.yml`**, 157 lines.

It is the right bake-off because it is the template whose size is mostly
*duplicated mechanics* rather than decision logic — which is precisely the thing
a composition engine claims to delete, so the test is fair rather than rigged
in either direction. Specifically, three job bodies (`test`, `ruff`, `bandit`)
each repeat the same four-step preamble verbatim: `actions/checkout` at pinned
SHA, `actions/setup-python` at pinned SHA, `pip install uv==<version>`, then
`uv sync --frozen`. I opened the file and confirmed the repetition: the string
`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` appears 3 times
and `actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97` appears 3
times, in jobs `test` (lines 92-115), `ruff` (lines 117-136) and `bandit`
(lines 138-157). If Dagger cannot collapse that, it cannot collapse anything in
this repo.

I considered and rejected two alternatives:

- `reusable-project-home.yml` (250 lines, the longest file) has the most
  bespoke logic, but it is the Project Home reporting boundary the brief says
  to preserve. Porting it is exactly the move that risks handing orchestration
  authority to a new service, and it is the wrong thing to test first.
- `reusable-contract-freshness.yml` (141 lines) contains real decision logic
  (`expect: current | noncurrent | warn` at lines 113-141), but almost all of it
  is already delegated to an external tool, `contractctl`, whose exit code the
  workflow propagates. Porting it would wrap one `python3` call in a second
  execution engine and delete nothing.

Current file list and line counts for the picked workflow and its
neighbours, from `wc -l .github/workflows/*.yml`:

| File | Lines |
|---|---|
| `.github/workflows/reusable-project-home.yml` | 250 |
| `.github/workflows/self-smoke.yml` | 180 |
| `.github/workflows/reusable-uat.yml` | 179 |
| **`.github/workflows/reusable-python.yml`** | **157** |
| `.github/workflows/reusable-node.yml` | 148 |
| `.github/workflows/reusable-contract-freshness.yml` | 141 |
| `.github/workflows/reusable-container-smoke.yml` | 131 |
| `.github/workflows/reusable-secret-scan.yml` | 51 |
| `.github/workflows/actionlint-selfcheck.yml` | 46 |
| `.github/workflows/secret-scan-selfcheck.yml` | 15 |
| total | 1298 |

There are no composite actions and no standalone scripts in this repo. `find`
over the tree returns only the ten workflows above, the fixtures, the two docs
(`README.md`, `AGENTS.md`, `docs/ACTIONS-COST-DISCIPLINE.md`) and
`pins/ACTIONS.md`. There is no `scripts/` directory and no `action.yml`/
`action.yaml` anywhere — so "duplicated scripts removed" is a non-applicable
row in the comparison table, and I say so rather than inventing a saving.

Structural breakdown of `reusable-python.yml` that drives the verdict:

| Region | Lines | Counted as |
|---|---|---|
| Header comment (lines 1-11) | 11 | documentation |
| `on: workflow_call: inputs:` (lines 13-86) | 74 | public interface |
| `permissions:` (lines 88-89) | 2 | GitHub plumbing |
| `jobs:` block (lines 91-157) | 67 | the part Dagger could replace |

## The Dagger prototype shape

I wrote a throwaway Python-SDK module at
`tools/bakeoff/python-module/` (uncommitted scratch, deliberately outside
`.github/workflows/` so no existing file is touched). `dagger-module.toml`:

```toml
name = "python-pipeline"
engineVersion = "v0.21.10"

[runtime]
source = "python"
```

`src/ci_harness_python/__init__.py`, 77 lines, reproducing the three jobs with
the same defaults `pins/ACTIONS.md` records (CPython 3.12, uv 0.11.28):

```python
"""Throwaway bake-off port of .github/workflows/reusable-python.yml.

Scope: reproduce the three jobs (test, ruff, bandit) that reusable-python.yml
declares, using the same defaults pins/ACTIONS.md records (CPython 3.12,
uv 0.11.28). Inputs mirror the workflow_call inputs one-for-one so the call
contract is comparable. NOT COMMITTED - research scratch only.
"""

import shlex
from typing import Annotated, List

import dagger
from dagger import Doc, dag, field, function, object_type


@object_type
class PythonPipeline:
    source: dagger.Directory

    project_directory: Annotated[str, Doc("Directory holding pyproject.toml and uv.lock")] = field(default=".")
    python_version: Annotated[str, Doc("CPython version")] = field(default="3.12")
    uv_version: Annotated[str, Doc("Exact uv version")] = field(default="0.11.28")
    sync_args: Annotated[str, Doc("Extra args for uv sync --frozen")] = field(default="")
    pytest_args: Annotated[str, Doc("Args for uv run pytest")] = field(default="")
    post_test_commands: Annotated[str, Doc("Repo-owned gates after pytest")] = field(default="")
    enable_ruff: Annotated[bool, Doc("Add the ruff job")] = field(default=False)
    ruff_args: Annotated[str, Doc("Args for uv run ruff")] = field(default="check .")
    enable_bandit: Annotated[bool, Doc("Add the bandit job")] = field(default=False)
    bandit_args: Annotated[str, Doc("Args for uv run bandit")] = field(default="-q -r .")

    @classmethod
    def create(cls, ws: dagger.Workspace):
        return cls(source=ws.directory("/"))

    # One _synced() replaces the checkout + setup-python + pip-install-uv +
    # uv sync block that reusable-python.yml repeats verbatim in all 3 jobs.
    def _synced(self) -> dagger.Container:
        return (
            dag.container()
            .from_(f"ghcr.io/astral-sh/uv:python{fq(self.python_version)}-bookworm-slim")
            .with_workdir(f"/src/{self.project_directory}")
            .with_directory("/src", self.source)
            .with_mounted_cache("/root/.cache/uv", dag.cache_volume("uv-cache"))
            .with_exec(["uv", "sync", "--frozen", *shlex.split(self.sync_args)])
        )

    @function
    async def test(self) -> str:
        """Run uv run pytest (the workflow's `test` job)."""
        ctr = self._synced().with_exec(["uv", "run", "pytest", *shlex.split(self.pytest_args)])
        if self.post_test_commands:
            ctr = ctr.with_exec(["bash", "-euo", "pipefail", "-c", self.post_test_commands])
        return await ctr.stdout()

    @function
    async def ruff(self) -> str:
        """Run uv run ruff (the workflow's `ruff` job)."""
        return await self._synced().with_exec(["uv", "run", "ruff", *shlex.split(self.ruff_args)]).stdout()

    @function
    async def bandit(self) -> str:
        """Run uv run bandit (the workflow's `bandit` job)."""
        return await self._synced().with_exec(["uv", "run", "bandit", *shlex.split(self.bandit_args)]).stdout()

    @function
    async def all_jobs(self) -> List[str]:
        """Run the enabled jobs concurrently, as three GitHub jobs would."""
        jobs = {"test": self.test}
        if self.enable_ruff:
            jobs["ruff"] = self.ruff
        if self.enable_bandit:
            jobs["bandit"] = self.bandit
        results = await dagger.gather(*[fn() for fn in jobs.values()])
        return [out for _, out in sorted(zip(jobs, results), key=lambda kv: kv[0])]


def fq(version: str) -> str:
    return ".".join(version.split(".")[:2])
```

Note what the module *cannot* express, which is the substance of the finding:
it has no `permissions:` block, no `runs-on:` selector (the `runs-on` input
that lets private repos pass `vars.CI_RUNNER_LIGHT` then `vars.CI_RUNNER`, see
`reusable-python.yml` lines 16-23), no `concurrency` group, and no notion of a
`workflow_call` input being a *public interface consumers call by name*. The
`runs-on` omission alone is disqualifying for this estate: private-repo Actions
minutes are a hard monthly budget (`reusable-python.yml` lines 19-20,
`docs/ACTIONS-COST-DISCIPLINE.md`), so a port that cannot select the runner
label cannot be adopted.

Also note `uv_version` is declared but never consumed by `_synced()`. That is
not a sloppiness in my prototype; it is the honest shape of the port. In the
YAML, `uv-version` is a *contract input* — callers can and do override it, and
`pins/ACTIONS.md` records 0.11.28 as the value "bumped only via this table". A
Dagger module that pins uv in a base image tag (`ghcr.io/astral-sh/uv:...`)
moves the version out of the input surface and into an image reference, so
either the input becomes a lie or the image tag must become parameterized. Both
are worse than the four YAML lines they replace.

## What the prototype run showed

The Dagger CLI binary was downloaded with `python3 urllib` into `tools/` and
unpacked with the `tarfile` module, per the prototype rules:

```
GET https://github.com/dagger/dagger/releases/download/v0.21.10/dagger_v0.21.10_linux_amd64.tar.gz
bytes 21945685 sha256 f9ee083767dd12cdac583f9db3fedbebbbb3064f69152998be1f121d1a6cc103
members ['LICENSE', 'dagger']
extracted 64573602
```

**What ran.** The CLI itself runs without a container engine:

```
$ ./tools/dagger version
dagger v0.21.10 (image://registry.dagger.io/engine:v0.21.10) linux/amd64
```

The module source parses:

```
$ python3 -c "import ast; ast.parse(open('tools/bakeoff/python-module/src/ci_harness_python/__init__.py').read()); print('AST parse OK')"
AST parse OK, lines: 78
```

**What did not run, and exactly why.** Every command that needs the Dagger
*engine* failed. The engine is a container and `docker` is denied by policy in
this environment. The exact command and the exact error:

```
$ ./tools/dagger call
✘ connect 0.0s ERROR
✘ exec docker version 0.0s ERROR
Client: Docker Engine - Community
 Version:           29.8.2
 API version:       1.56
 Go version:        go1.26.8
 Git commit:        7fc2dff
 Built:             Wed Sep 30 19:36:45 2026
 OS/Arch:           linux/amd64
 Context:           default
failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory
! failed to run command [docker version]: exit status 1
```

The same `exec docker version` failure is returned verbatim by `dagger check`,
`dagger generate`, `dagger up`, `dagger shell`, `dagger init --sdk=python
--name=x` and `dagger module init python --name=harness`. `dagger version` is
the only command that succeeds without the engine.

**Stages the issue asked for, and their status:**

| Stage | Ran? | Why |
|---|---|---|
| Module shape authored | yes | — |
| Module parses | yes | — |
| `dagger version` | yes | CLI needs no engine |
| Module codegen / `dagger generate` | no | engine blocked: `dial unix /var/run/docker.sock: connect: no such file or directory` |
| `dagger init` workspace | no | same engine error |
| Pipeline run locally | no | same engine error |
| Pipeline run on the self-hosted path | no | same engine error; additionally UNVERIFIED in principle, since `runs-on` has no module equivalent |
| Pipeline run from GitHub Actions | no | same engine error |

So **no pipeline stage ran, locally or in CI, and no container was built,
started, cached, or torn down in this study.** No command output in this
document is simulated; the runs above are the complete set of Dagger
invocations that produced output.

**A second finding, from the CLI itself.** The shipped `v0.21.10` binary's
command surface does not match its own documentation. `dagger --help` lists
`call`, `config`, `core`, `develop`, `functions`, `init`, `install`,
`uninstall`, `update`, `query`, `run`, `completion`, `help`, `lock`,
`toolchain`, `version`. The commands the docs instruct you to run are absent:

```
$ ./tools/dagger settings
Error: unknown command or file "settings" for "dagger"
$ ./tools/dagger workspace
Error: unknown command or file "workspace" for "dagger"
$ ./tools/dagger sdk
Error: unknown command or file "sdk" for "dagger"
$ ./tools/dagger list
Error: unknown command or file "list" for "dagger"
```

And the documented 1.0 module-init invocation is rejected on flag parsing
before any engine contact:

```
$ ./tools/dagger module init python --name=harness
Error: unknown flag: --name
```

while the 0.21.10 form works (`dagger init --sdk=go`, per
`dagger init --help`: "USAGE dagger init [options] [path]"). Separately,
`./tools/dagger module --help` and `./tools/dagger module init --help` exit 0
while printing the *top-level* help, not subcommand help — a trap for anyone
scripting against this CLI. An estate whose whole premise is pinned,
reproducible CI would be adopting a CLI whose documented commands do not
exist in its own current release.

## The comparison table

Every row the issue names. "Current" = `reusable-python.yml` at HEAD. "Dagger"
= what the prototype would mean, judged from the code above and the Dagger
docs cited below. Rows I could not verify are marked UNVERIFIED rather than
guessed.

| Dimension | Current (`reusable-python.yml`) | Dagger prototype | Verdict |
|---|---|---|---|
| Lines removed from workflow YAML | 67 lines of job bodies (lines 91-157) | 77-line module replaces them | **Net negative.** 10 lines *added*; nothing deleted |
| Configuration removed | none; inputs are the contract | none; 10 module fields mirror the same inputs | **No change.** Same public interface, new place to maintain it |
| Duplicated scripts removed | n/a — this repo has no `scripts/` directory and no composite actions | n/a | **Not applicable.** No saving exists to claim |
| Caching behaviour | Implicit: `actions/setup-python` cache + runner image; no explicit cache | Explicit `with_mounted_cache("/root/.cache/uv", ...)` | **Better in principle**, but a new cache-key concept and a self-hosted cache-lifetime question. UNVERIFIED without a run |
| Container and service setup | None; runs on the bare runner | Each job becomes a container from a base image | **Worse.** New layer; image pinning moves into `dagger.lock` |
| Secret handling | None for this template; secrets reach templates as `workflow_call` `secrets:` inputs (see `reusable-uat.yml` lines 100-103) | `dagger.Secret` + `with_secret_variable` | **Different, not simpler.** Would need re-specifying per template |
| Logs and debugging | `actions/setup-*` step logs in the run UI; trivially greppable | TUI spans plus Dagger Cloud URLs | **Worse for this estate.** Cloud is a second login |
| Failure semantics | Native: one red `uses:` job fails the run; `continue-on-error` is forbidden on `uses:` jobs (`self-smoke.yml` lines 8-14 relies on this) | Engine-level exceptions; GitHub sees one `dagger call` exit code | **Materially worse.** Loses the per-job inversion trick the self-smoke depends on |
| Local/CI parity | Partial: `AGENTS.md` lines 41-44 give manual fixture commands, CI is the gate | Claimed as a headline feature | **UNVERIFIED.** Could not run locally |
| Startup overhead | ~0; steps are native actions | Engine container pull + start per run | **Worse.** A cold Dagger engine is seconds to tens of seconds before any work starts |
| Dependency and update burden | 5 pinned action SHAs in one table (`pins/ACTIONS.md`), bumped in one commit | Action pins *plus* a Dagger CLI pin *plus* `dagger.lock` image pins *plus* SDK pins | **Worse.** One table becomes three |
| Accessibility of failure output | GitHub run UI, per step | TUI or Cloud trace URL | **Worse.** Breaks the current "read CI with `gh pr checks`" habit in `AGENTS.md` line 46 |
| Compatibility with pinned tooling | uv 0.11.28, CPython 3.12, action SHAs, all centrally pinned | Must re-pin uv into a base image tag; `uv_version` becomes unused | **Worse.** Conflicts with the single-source-of-truth pin design |

## The exact code and configuration that could be deleted, file by file

**Nothing.** This is the finding, stated plainly rather than softened.

| File | Lines | Deletable by a Dagger port? |
|---|---|---|
| `.github/workflows/reusable-python.yml` | 157 | **No.** The 74-line `workflow_call` inputs block is the public interface consumers bind to; `AGENTS.md` lines 54-56 call it a public interface and require Rylee's approval to change. The 67-line jobs block is replaced by 77 lines of Python. Net +10 lines, one file becomes two |
| `pins/ACTIONS.md` | 48 | **No.** `actions/checkout` and `actions/setup-python` SHAs would still be needed for `self-smoke.yml`, `actionlint-selfcheck.yml` and the four other templates; Dagger adds a pin set rather than removing one |
| `README.md` template table row for `reusable-python.yml` | 1 line | **No.** Consumers still need an adoption snippet, and it would now need a Dagger prerequisite |
| `self-smoke.yml` job `python` (lines 42-48) | 7 | **No.** Still the proof that the template contract works; a Dagger port would replace it with a different 7-line job, not delete it |
| `docs/ACTIONS-COST-DISCIPLINE.md` | 52 | **No.** Still applies; `runs-on` selection and job-folding guidance would grow, not shrink |

Counting honestly against the issue's decision rule: the port produces *GitHub
Actions YAML calling Dagger, which calls the same `uv sync --frozen` and
`uv run pytest`*. That is the shape the issue names as grounds for rejection.

## New dependencies and services

Adopting Dagger would add to this estate:

1. **A Dagger engine container on every runner**, plus the CLI binary, pinned.
   Verified present in the shipped binary as the default engine address:
   `dagger v0.21.10 (image://registry.dagger.io/engine:v0.21.10)`.
2. **A Dagger module language and runtime** — here the Python SDK,
   `dagger-io` on PyPI at `0.21.10`, released 2026-09-30, `requires_python >=3.10`.
   The estate's Python default is 3.12 (`pins/ACTIONS.md`), which is compatible.
3. **A `dagger.toml` workspace file and a `dagger.lock`.** `dagger.toml`
   resolves to two different roles in 0.x vs 1.0 (`dagger.json` vs
   `dagger.toml` / `dagger-module.toml`), so this file is itself a migration
   surface.
4. **A `sdk/` directory of generated client code**, which the docs say to
   commit.
5. **Dagger Cloud**, for the trace UI that `--web` opens and for Cloud Checks.
   This is a hosted service and a second identity to manage.
6. **A second observability path.** Engine resource metrics export to an OTLP
   endpoint, but that is engine CPU/memory, not pipeline traces — see the next
   section.

The boundary is preserved: GitHub Actions remains the trigger, and nothing here
gives Dagger approval authority. Project Home stays the task and approval
authority; `reusable-project-home.yml` is untouched by this study.

## Beta and stability risks

**The docs are still beta.** `docs.dagger.io` renders a version selector reading
`DAGGER 1.0-beta 0.21 0.20 0.19 0.18 0.17 0.16` and the quickstart page is
banner-labelled `Version: 1.0-beta`. Read 2026-10-06. The current release is
`v0.21.10`, published 2026-09-30 — still a `0.x` line, one minor series below
the `1.0-beta` the docs describe. So the documented API is *ahead of* the
shipped release.

**Churn is high.** Core release tags on the first page of the GitHub releases
API, read 2026-10-06: `v0.21.10` (2026-09-30), `v0.21.9` (2026-08-26),
`v0.21.8` (2026-07-29), `v0.21.7` (2026-06-17), `v0.21.6` (2026-06-11),
`v0.21.5` (2026-06-10), `v0.21.4` (2026-06-03), `v0.21.3` (2026-05-30),
`v0.21.2` (2026-05-30), `v0.21.1` (2026-05-29), `v0.21.0` (2026-05-26),
`v0.20.8` (2026-05-06), `v0.20.7` (2026-05-04). Thirteen core releases in
roughly five months, with several same-day or two-day gaps — a `pins/ACTIONS.md`
bump protocol that assumes a deliberate, reviewed cadence would not survive
this cadence.

**The self-hosting story is a stub.** The `Self-hosting` page of
`docs.dagger.io` currently contains the entire body `TODO`, read 2026-10-06.
For an estate that runs self-hosted runners and treats private Actions minutes
as a hard budget, the self-hosting documentation being empty is a direct risk,
not an abstract one.

**The CLI is ahead-of/behind its own docs**, as shown above: `dagger settings`,
`dagger workspace`, `dagger sdk`, `dagger list` and `dagger module init
--name` are all documented and none of them work in `v0.21.10`.

## Migration and rollback path

Recorded for completeness; **this study does not migrate estate CI and no
migration was performed.**

Migration would be additive-then-parallel: add a Dagger module, add a *second*
job to `self-smoke.yml` running both the YAML template and the Dagger module
against `fixtures/py-demo`, compare, then flip consumers one at a time — but
consumers call templates at `@main` (`AGENTS.md` lines 50-53), so any
input-level change is instantly live for `personal-world`. Every input rename
or removal is breaking and needs Rylee's approval (`AGENTS.md` lines 54-56,
66-67).

Rollback would be: revert the commit, delete the module, and consumers see the
old `@main` again with no coordination. That is a genuinely good property of
the current design and Dagger does not improve on it — but it is also a
property that means *there is no reason to migrate*. When the cost of a wrong
migration is low and the benefit is measured in ten lines, the default from
Rylee's rule is to leave the working machinery alone.

## The OpenTelemetry reachability finding

**Dagger cannot currently export useful pipeline traces into an estate
collector. Adopting it for tracing would create an observability island.**

What the documentation actually offers, read 2026-10-06:

- The only OTLP export Dagger documents is **engine resource metrics**, gated
  off by default. From the engine config reference: enable with
  `{"telemetry": {"resourceMetrics": true}}`, and it requires
  `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` in the engine process environment.
  It reads cgroup v2 files and reports "CPU and memory charged to that
  cgroup, including its descendants" — that is the *engine's own* resource
  usage, not pipeline spans.
- The published engine schema
  (`https://docs.dagger.io/reference/engine.schema.json`, read 2026-10-06)
  confirms `TelemetryConfig` has exactly two properties, `resourceMetrics`
  (boolean, default `false`) and `engineEvents` (boolean, default `false`,
  and it "requires `DAGGER_CLOUD_TOKEN`"). There is no traces property.
- Docs are explicit that this is a *separation*: "Engine resource metrics use a
  separate meter provider, reader, and exporter. They do not use client
  telemetry providers or the client telemetry proxy. Client and execution
  metrics, traces, logs, and Prometheus reporting keep their existing
  configuration and routes."
- Where the traces that Dagger *does* advertise actually surface: the test
  modules document that tests "appear as spans in the Dagger TUI and Dagger
  Cloud" (pytest, Jest, Vitest and Go module pages). The `dagger --web` flag
  opens a "trace URL". Both are Dagger surfaces.
- There is no telemetry, tracing, or observability page anywhere in the
  `docs.dagger.io` sitemap — I enumerated all 138 page URLs; the only
  matches for cloud/engine/trace keywords are `cloud-checks` and the
  `api/cloud`, `api/engine*` type stubs.

What I could verify on the shipped binary: `./tools/dagger v0.21.10` contains
the standard OpenTelemetry Go SDK including the gRPC string
`opentelemetry.proto.collector.trace.v1.TraceService/Export` and the variables
`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`,
`OTEL_TRACES_EXPORTER` and `OTEL_TRACES_SAMPLER`. **UNVERIFIED:** whether any
of this is reachable as a *documented, supported* configuration path for
Dagger's own pipeline spans, or is only inherited library code linked into the
binary and used for the client-proxy path the docs call a separate provider.
There is no documented knob in `engine.json` or in the CLI `--help` flag list
that points it at an arbitrary collector endpoint.

Conclusion against the issue's requirement — "do not accept proprietary
telemetry as the only useful trace path": the only *useful* trace path
documented is the Dagger TUI and Dagger Cloud, which is proprietary. The only
*non-proprietary* export path is engine resource metrics, which is not traces.
The estate collector would receive engine CPU/memory, not pipeline spans. That
is the definition of a separate observability island, and on this axis alone
Dagger adds a service without adding estate-visible proof.

## Sources

Read 2026-10-06 unless stated.

Repository under study (this clone, local commands, no URL needed):

- `git rev-parse HEAD` → `aa30fbeafdb022128fce119a10b9008a7d466b94`
- `wc -l .github/workflows/*.yml` → the 1298-line table above
- `.github/workflows/reusable-python.yml` — read in full; jobs at lines 92-115,
  117-136, 138-157
- `.github/workflows/reusable-project-home.yml`, `reusable-node.yml`,
  `reusable-container-smoke.yml`, `reusable-contract-freshness.yml`,
  `reusable-uat.yml`, `reusable-secret-scan.yml`, `self-smoke.yml`,
  `actionlint-selfcheck.yml`, `secret-scan-selfcheck.yml` — all read in full
- `AGENTS.md`, `README.md`, `docs/ACTIONS-COST-DISCIPLINE.md`, `pins/ACTIONS.md`,
  `.project/CURRENT.md`, `.claude/settings.json`, `.gitignore`, all five
  `fixtures/*` directories — read
- `./tools/dagger version`, `./tools/dagger --help`, `./tools/dagger call`,
  `./tools/dagger settings|workspace|sdk|list`,
  `./tools/dagger module init python --name=harness` — exact output quoted above

External:

- Dagger releases, `https://api.github.com/repos/dagger/dagger/releases/latest`
  → `v0.21.10`, published 2026-09-30T16:26:37Z, `prerelease: false`
- Dagger release list, `https://api.github.com/repos/dagger/dagger/releases?per_page=100`
  → the 13 core `v0.x` tags and dates in the stability section
- Dagger CLI asset `dagger_v0.21.10_linux_amd64.tar.gz`, 21945685 bytes,
  sha256 `f9ee083767dd12cdac583f9db3fedbebbbb3064f69152998be1f121d1a6cc103`,
  from `https://github.com/dagger/dagger/releases/download/v0.21.10/dagger_v0.21.10_linux_amd64.tar.gz`
- Dagger docs index, `https://docs.dagger.io/` → version selector
  `DAGGER 1.0-beta 0.21 0.20 0.19 0.18 0.17 0.16`
- Dagger quickstart, `https://docs.dagger.io/getting-started/quickstart` →
  page banner reads `Version: 1.0-beta`
- Dagger Python SDK reference,
  `https://docs.dagger.io/reference/sdks/python` → `@object_type`, `@function`,
  `field()`, `dagger.Workspace`, `dagger-module.toml`, `dagger.toml` split,
  `sdk/` checked in, `dagger secret` handling via `with_secret_variable`
- Dagger config reference, `https://docs.dagger.io/reference/config-files/dagger-toml`
  → `dagger.toml` keys, `dagger.lock`, `dag://` module wiring
- Dagger engine config, `https://docs.dagger.io/reference/config-files/engine-json`
  and `https://docs.dagger.io/reference/engine.schema.json` → `TelemetryConfig`
  with exactly `resourceMetrics` and `engineEvents`; the "Separation from
  client telemetry" and "Accounting boundary" sections
- Dagger self-hosting, `https://docs.dagger.io/self-hosting` → body is `TODO`
- Dagger CLI reference, `https://docs.dagger.io/reference/cli/` → the command
  list and per-command flags the shipped binary does not match
- Dagger cloud checks, `https://docs.dagger.io/getting-started/cloud-checks` →
  Git-event-triggered runs on Dagger's Cloud Engines
- Dagger pytest / Jest / Vitest / Go module pages under
  `https://docs.dagger.io/reference/modules/` → test spans land "in the Dagger
  TUI and Dagger Cloud"
- Dagger sitemap, `https://docs.dagger.io/sitemap.xml` → 138 page URLs; no
  telemetry, tracing or observability page
- `dagger-io` on PyPI, `https://pypi.org/pypi/dagger-io/json` → version
  `0.21.10`, uploaded 2026-09-30T16:28:12Z, `requires_python >=3.10`
- `https://github.com/rhysd/actionlint/releases/download/v1.7.12/` — the
  actionlint tarball referenced by `actionlint-selfcheck.yml`; not downloaded,
  cited as the current pin recorded in `pins/ACTIONS.md`

## Recommendation

On the counts: the prototype replaces 67 lines of YAML job bodies with 77
lines of module, deletes no file, keeps the 74-line `workflow_call` input
interface intact, and cannot express `runs-on` — the input private repos rely on
to avoid the Actions minute ceiling. Dagger's documented OTLP export is engine
cgroup metrics, while the traces it advertises land only in the Dagger TUI and
Dagger Cloud. Under the rule Rylee set, a technology that adds a service and
removes no meaningful complexity is rejected by default.

REJECT -- Dagger replaces 67 lines of `reusable-python.yml` with 77 lines of module and deletes nothing, while adding an engine, a workspace file, a lockfile and a proprietary trace path.

## Unresolved

- **Whether Dagger's pipeline spans can be exported to an arbitrary OTLP
  endpoint.** The shipped binary contains a full OpenTelemetry Go SDK including
  `opentelemetry.proto.collector.trace.v1.TraceService/Export`, but no
  documented knob in `engine.json` or the CLI exposes it for pipeline spans,
  and the engine cannot be started here to test it. UNVERIFIED — and this is
  the single question most likely to change the verdict, in Dagger's favour.
  Someone with a working Docker daemon should answer it before this
  conclusion is treated as final on the tracing axis.
- **Real caching behaviour.** The prototype's
  `with_mounted_cache("/root/.cache/uv", ...)` is plausible but was never
  executed. Whether it beats or loses to the current `actions/setup-python`
  cache on a self-hosted runner is UNVERIFIED.
- **Startup overhead.** No measurement was possible without the engine. The
  cost of an engine cold start per job on the private-runner budget is
  UNVERIFIED and is the largest unquantified risk to `docs/ACTIONS-COST-DISCIPLINE.md`.
- **`dagger-gh` and GitHub Actions integration.** No official
  `dagger/dagger-github-action` repository exists — a GitHub API lookup for
  that path returned HTTP 404 on 2026-10-06. How a Dagger module would be
  triggered from a GitHub Actions job without adding an unpinned third-party
  action is UNVERIFIED; the obvious shape (curl the CLI in a `run:` step) is
  worse for pinning hygiene than what `pins/ACTIONS.md` already enforces.
- **Whether `reusable-project-home.yml` (250 lines) would fare better.** I
  deliberately did not test it, because the brief preserves that boundary and
  porting it is the move most likely to leak orchestration authority. It is the
  natural second candidate if anyone revisits this.
- **Whether the 1.0-beta command surface lands as documented.** If a future
  1.0 release ships `dagger settings` / `dagger workspace` / `dagger sdk` and a
  stable module format, the CLI-vs-docs mismatch finding weakens. The
  `Self-hosting` page being `TODO` remains a live risk either way.
- **Whether the other six templates behave like the python one.** I baked off
  one workflow as the issue asked. `reusable-container-smoke.yml` (131 lines,
  docker build/run/healthz-loop) is the most likely to show a larger Dagger
  win, since Dagger models containers and services natively — but it is also
  the one where the estate already has a working, fail-closed loop with
  container-log capture on failure, so the bar for "delete real logic" is
  higher there.