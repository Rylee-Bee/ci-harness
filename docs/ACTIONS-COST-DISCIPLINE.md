# GitHub Actions cost discipline

Recorded 2026-10-05 after the private-repository Actions allowance reached roughly 90% usage within about one day of high-volume agent work.

## Principle

**Preserve proof; fold duplicate billing.**

Fast agents multiply workflow events. CI design must therefore optimize for evidence per billed job, not for the number of independently named jobs.

## Default shape for private repositories

1. **Pull requests are the merge gate.** Run the required validation on `pull_request`.
2. **Do not automatically repeat the identical validation on `push: main`** when branch protection guarantees that main changes through a checked PR. Keep `workflow_dispatch` as a repair/debug path.
3. **Keep post-merge jobs only when they prove something different**, such as packaging the exact merged tree, deployment, publication, migration, or runtime verification.
4. Add workflow concurrency where safe:
   ```yaml
   concurrency:
     group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
     cancel-in-progress: true
   ```
5. **Fold short independent jobs** when they share setup and do not need isolation. GitHub-hosted billing rounds job execution, so many tiny jobs can cost much more than one sequential validation job.
6. Use `paths` / `paths-ignore` when a class of changes cannot affect the proof. Docs-only changes should not install browsers or build containers without a concrete reason.
7. Secret scanning should be proportional:
   - PR path: changed/current tree or shallow scan where the repository's threat model permits it.
   - periodic/manual path: full-history scan.
   - privacy-sensitive repositories may intentionally keep a stronger PR scan; document the exception.
8. Expensive drift/security audits belong on a deliberate schedule unless they are true merge gates.
9. Public repositories on standard GitHub-hosted runners are not the private-minute optimization target. Optimize them for latency/clarity, not merely for quota.
10. Self-hosted runners are an optional later optimization for trusted workloads. Do not weaken isolation or make a workstation a hidden deployment authority merely to save minutes.

## Agent rule

When creating or changing CI in a private estate repository, inspect the existing trigger topology before adding a workflow. Prefer extending/folding an existing gate over adding another job or another PR+push pair.

Before calling CI optimization complete, answer:

- What distinct proof does each remaining workflow/job provide?
- Does the same commit get the same proof twice?
- Can obsolete runs be cancelled?
- Can shared setup be folded?
- Can path filtering safely avoid irrelevant work?
- Is an expensive full-history/browser/container check running more often than its evidence value requires?
- Did required check names, branch protection, release/deploy semantics, or authority boundaries change?

Cost reduction is **not** permission to remove a meaningful gate. If two checks prove different things, keep both.

## 2026-10-05 first pass

The first estate pass targeted duplicate PR + post-merge validation in private repositories, while preserving PR gates, manual dispatch, existing concurrency cancellation, and release/deploy workflows. Homelab already contained several of these optimizations and should be treated as prior art.

Follow-up work should measure actual Actions usage after the trigger changes land before introducing self-hosted runners or weakening checks.

## 2026-10-06 ratification — superseded for this estate

The line above was written on 2026-10-05. Twenty self-hosted runners had already been registered and running by then, so it read as though the decision were still ahead when it had in fact already been made.

**The estate owner ratified the self-hosted runner fleet on 2026-10-06.** For this estate that call is made and the guidance above is superseded. The reasoning and the measured state live in `agent-platform/docs/LOCAL-CI.md`; the short version is that the fleet runs CI, does not deploy, and is now watched by a 15-minute timer because a stopped-not-disabled fleet produced a nine-day silent outage (jobs routed at an offline label stay `queued` forever, which is indistinguishable from running).

The general principle is unchanged and still applies to any *new* runner adoption: measure actual Actions usage first, and do not weaken a meaningful gate to save minutes. Nothing about the ratification weakens isolation or makes the workstation a deployment authority.
