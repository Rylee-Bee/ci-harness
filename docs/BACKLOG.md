# ci-harness backlog

This file is the tracking doc for work that was open in GitHub Issues in this repository and was closed as not planned on 2026-10-07, so the issue queue could reach zero.

The issue bodies themselves are not edited; the summaries below are ours, written from the bodies.

To restart an item, reopen the linked issue, or open a new one, and delete its row here.

It was built by one rule: every issue open in this repository on 2026-10-07 is listed, newest first, with nothing added and nothing dropped.

## Issues closed on 2026-10-07

### #20 — research: see whether Dagger can shrink the CI harness

- Issue: https://github.com/Rylee-Bee/ci-harness/issues/20
- Opened: 2026-10-06 · Labels: none
- Status on 2026-10-07: closed as not planned on 2026-10-07 — tracked here

The issue asks whether Dagger could move repeatable pipeline execution out of GitHub workflow YAML while ci-harness keeps the estate-specific parts, without migrating estate CI as part of the research. It asks for a bake-off on one existing reusable workflow with meaningful logic, rather than a general comparison. The boundary to preserve is that ci-harness owns shared CI and golden paths plus the narrow Project Home reporting boundary, GitHub Actions may stay the trigger and orchestrator even if execution moves, and Project Home stays the task and approval authority. Maturity is part of the evaluation, since Dagger's own docs ship as 1.0-beta and churn is expected. The stated decision rule is that adoption is recommended only if real ci-harness workflow or script logic can be deleted or substantially simplified, and rejected if the result is GitHub YAML calling Dagger calling the same scripts. The study that answered it is kept at `docs/research/2026-10-06-dagger-vs-ci-harness.md`.

Next step, when this is picked up: Re-read the recorded study conclusion before commissioning any fresh bake-off.

### #19 — observability: emit OpenTelemetry CI/CD traces and propagate estate context

- Issue: https://github.com/Rylee-Bee/ci-harness/issues/19
- Opened: 2026-10-06 · Labels: none
- Status on 2026-10-07: closed as not planned on 2026-10-07 — tracked here

The issue asks ci-harness to emit OpenTelemetry traces for CI/CD and to propagate estate context, as the parent observability spine for the homelab repo. It requires adopting the OpenTelemetry release-candidate CI/CD semantic conventions for pipeline runs, task runs, metrics and logs, rather than inventing a private telemetry vocabulary. The prototype is one reusable workflow instrumented end to end, representing pipeline run, pipeline task or job run, repository, ref, revision, outcome, duration, runner class, and Project Home task correlation when a caller supplies it. It also asks for W3C trace context to be propagated into called reusable workflows and into any scripts the workflows launch. A dependency is stated: the parent spine lives in homelab #229.

Next step, when this is picked up: Confirm the CI/CD semantic conventions have left release-candidate before writing any telemetry vocabulary.

### #18 — Add reusable Grype vulnerability scanning beside SBOM generation

- Issue: https://github.com/Rylee-Bee/ci-harness/issues/18
- Opened: 2026-10-05 · Labels: none
- Status on 2026-10-07: closed as not planned on 2026-10-07 — tracked here

The issue asks for a reusable Grype vulnerability-scanning workflow to sit alongside Renovate, which decides what can be updated, Syft, which reports what is present, and Grype, which reports what known vulnerabilities affect that inventory. It should live in ci-harness rather than being reimplemented per repo. The workflow should scan a Syft-generated SBOM, a caller-provided path, or optionally a built image, preferring the SBOM when one already exists. It requires a pinned Anchore/Grype implementation with pins recorded in `pins/ACTIONS.md`, a configurable severity cutoff, support for only-fixed, and a portable machine-readable report, preferring SARIF for findings while keeping raw or JSON output available. A dependency is implied by the ordering: the SBOM generation in #17 is the preferred input.

Next step, when this is picked up: Land the SBOM generation it consumes first, then scan that artifact.

### #17 — Add reusable Syft SBOM generation to the estate golden path

- Issue: https://github.com/Rylee-Bee/ci-harness/issues/17
- Opened: 2026-10-05 · Labels: none
- Status on 2026-10-07: closed as not planned on 2026-10-07 — tracked here

The issue asks for a reusable Syft-backed SBOM generation workflow, so software inventory is a standard golden-path step alongside Renovate rather than duplicated across repositories. It should generate an SBOM from a caller-provided path and/or a built image. The default format is CycloneDX JSON unless there is a strong compatibility reason to prefer SPDX. It requires a pinned Anchore/Syft implementation with pins kept in `pins/ACTIONS.md`, optional upload of the SBOM as a workflow artifact, and no write permissions for the common read-only case. It must work on GitHub-hosted and on the existing self-hosted runners, and must ship a real self-smoke fixture in ci-harness. The reusable should expose useful outputs such as artifact path and status without making callers depend on internal details. Vulnerability scanning of the resulting SBOM is the follow-on work tracked in #18.

Next step, when this is picked up: Write the self-smoke fixture and the CycloneDX JSON default before wiring any caller.