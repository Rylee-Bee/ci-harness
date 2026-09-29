// Self-smoke fixture for reusable-uat.yml.
//
// This is NOT a browser run. Its whole job is to prove the CALL CONTRACT that
// the reusable workflow promises, in the same positive-assertion style as the
// contract-freshness stale probe: it fails loudly if the template did not wire
// something through, rather than going green while quietly skipping it.
//
// It asserts three things a caller actually depends on:
//   1. UAT_READONLY reaches the repo-owned command at all (unset = broken wiring).
//   2. UAT_READONLY carries the value the `read-only` input asked for, so the
//      read-only posture is real and not decorative.
//   3. The command can write to the output directory the template uploads.
//
// Keep this dependency-free on purpose: the fixture's package-lock.json exists
// so the template's lockfile-gated `npm ci` and npm cache path are exercised too.
import { mkdirSync, writeFileSync } from "node:fs";

const readOnly = process.env.UAT_READONLY;

if (readOnly === undefined) {
  console.error("uat fixture: UAT_READONLY was not passed through by the template — the read-only posture is NOT being enforced");
  process.exit(1);
}
if (readOnly !== "1" && readOnly !== "0") {
  console.error(`uat fixture: UAT_READONLY must be "1" or "0", got ${JSON.stringify(readOnly)}`);
  process.exit(1);
}

const expected = process.env.FIXTURE_EXPECT_READONLY;
if (expected !== undefined && expected !== readOnly) {
  console.error(`uat fixture: template passed UAT_READONLY=${readOnly} but this job asked for ${expected} — the read-only input is not wired through`);
  process.exit(1);
}

const isReadOnly = readOnly === "1";

// Second half of the call contract: the target URL must reach the command as
// $UAT_URL. Optional for a caller, but if a job says what it expects, the
// wiring has to actually deliver it.
const expectedUrl = process.env.FIXTURE_EXPECT_URL;
if (expectedUrl !== undefined && process.env.UAT_URL !== expectedUrl) {
  console.error(`uat fixture: template passed UAT_URL=${JSON.stringify(process.env.UAT_URL)} but this job asked for ${JSON.stringify(expectedUrl)} — the uat-url input is not wired through`);
  process.exit(1);
}

const report = {
  ok: true,
  readOnly: isReadOnly,
  url: process.env.UAT_URL || "(none)",
  note: isReadOnly
    ? "would have sent: POST /api/example (blocked by read-only posture)"
    : "writes permitted (read-only explicitly disabled)",
};

mkdirSync("uat-out", { recursive: true });
writeFileSync("uat-out/findings.json", `${JSON.stringify(report, null, 2)}\n`);
writeFileSync(
  "uat-out/report.md",
  [
    "# UAT self-smoke fixture",
    "",
    `- read-only: \`${isReadOnly}\``,
    `- \`${report.note}\``,
    "",
    "This run proves the reusable-uat call contract only.",
    "",
  ].join("\n"),
);

console.log(`uat fixture ok: UAT_READONLY=${readOnly} (read-only=${isReadOnly})`);
