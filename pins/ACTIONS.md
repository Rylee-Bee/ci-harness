# Action & tool pins — single source of truth

Every pinned SHA in this repository's reusable workflows **must** appear in
this table. Bumping a pin = one commit here + matching edits in the workflow
files, landed together in `ci-harness`; adopting repos never hand-edit pins.
This table exists because the 2026-09-21 estate recon found real drift:
`checkout@v4.2.2` in one repo vs `@v7.0.1` in others.

Verification method column shows how each SHA was checked against the
upstream tag on the pin date (never copied blindly from an older workflow).

## GitHub Actions

| Action | Version | Commit SHA | Used in | Verified |
|---|---|---|---|---|
| [actions/checkout](https://github.com/actions/checkout) | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` | all workflows | `git ls-remote` 2026-09-21 |
| [actions/setup-python](https://github.com/actions/setup-python) | v7.0.0 | `5fda3b95a4ea91299a34e894583c3862153e4b97` | reusable-python, reusable-node | `git ls-remote` 2026-09-21 |
| [actions/setup-node](https://github.com/actions/setup-node) | v7.0.0 | `820762786026740c76f36085b0efc47a31fe5020` | reusable-node | `git ls-remote` 2026-09-21 |
| [actions/upload-artifact](https://github.com/actions/upload-artifact) | v7.0.1 | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` | reusable-node | `git ls-remote` 2026-09-21 |

## Pinned binaries

| Binary | Version | sha256 | Used in | Verified |
|---|---|---|---|---|
| [rhysd/actionlint](https://github.com/rhysd/actionlint) (linux_amd64 tarball) | 1.7.12 | `8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8` | actionlint-selfcheck.yml | official `checksums.txt` + release-API `digest` + independent re-download 2026-09-21 (first selfcheck run FAILED the gate on a transcription error — mechanism proven) |

## Toolchain & base-image pins

| Thing | Pin | Where it lives | Rationale |
|---|---|---|---|
| uv | 0.11.28 | `uv-version` input default in reusable-python.yml / reusable-node.yml | matches the version adopted repos already ran; bumped only via this table |
| CPython default | 3.12 | `python-version` input default | estate-wide test interpreter |
| Node default | 22 | `node-version` input default | matches personal-world e2e |
| nginx (fixture only) | 1.30.1-alpine | fixtures/container-demo/Dockerfile | pinned-tag exemplar: consuming repos pin their own base images |
| play-nice-contracts clone | **deliberately unpinned** — default-branch tip, `git clone --depth 1` over https | reusable-contract-freshness.yml | the cloned checkout's own revision is one of the pins the freshness check compares against the remote head; pinning the clone anywhere but tip would force a non-CURRENT verdict forever. The revision under test is the consumer's manifest pin. Fixture re-pins (current vs stale probe) stay manual, per this repo's own honesty rule |

Repo-specific pins (pytest in `uv.lock`, Playwright browsers, app base
images) stay in the consuming repo — that's semantics, not plumbing.

## Bump protocol

1. Resolve the new tag's commit: `git ls-remote https://github.com/<org>/<action>.git refs/tags/<tag>^{}`
   (dereference annotated tags; never trust a copied SHA).
2. Update this table **and** every workflow occurrence in one commit.
3. `actionlint-selfcheck` + `self-smoke` on ci-harness must go green before
   any consumer sees the change (consumers call `@main`).
