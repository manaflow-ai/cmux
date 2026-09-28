import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(webRoot, "..");
const result = spawnSync(
  "npx",
  [
    "--yes",
    "react-doctor@0.2.14",
    "web",
    "--full",
    "--json",
    "--json-compact",
    "--no-score",
    "--fail-on",
    "none",
  ],
  { cwd: repositoryRoot, encoding: "utf8" },
);

assert.equal(result.error, undefined, result.error?.message);
assert.equal(result.status, 0, result.stderr);

const report = JSON.parse(result.stdout);
const diagnostics = report.projects.flatMap((project) => project.diagnostics ?? []);
const correctnessRules = new Set([
  "button-has-type",
  "js-index-maps",
  "rendering-hydration-mismatch-time",
]);
const remaining = diagnostics.filter((diagnostic) =>
  correctnessRules.has(diagnostic.rule),
);

assert.deepEqual(
  remaining,
  [],
  `React Doctor reported fixed correctness diagnostics: ${JSON.stringify(remaining)}`,
);

console.log(
  `React Doctor 0.2.14: no ${[...correctnessRules].join(", ")} diagnostics`,
);
