// Self-smoke fixture: emits a dist/ bundle so the node template's build
// step and artifact upload have something real to produce.
import { mkdirSync, writeFileSync } from "node:fs";

mkdirSync("dist", { recursive: true });
writeFileSync("dist/index.txt", "ci-harness self-smoke ok\n");
