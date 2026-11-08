import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// Bun 1.3's synchronous spawn can miss the child's exit on Blacksmith runners
// and spin the test process until the job times out (manaflow-ai/cmux#14876).
// A blocked event loop also stops bun:test's own per-test timeout, so the hang
// is unbounded. Web tests run children through tests/helpers/run-child.ts.
const forbidden = /\b(spawnSync|execFileSync|execSync)\b/;
const testsRoot = fileURLToPath(new URL(".", import.meta.url));
const self = "no-sync-child-process.test.ts";

test("web tests never use synchronous child process APIs", () => {
  const offenders: string[] = [];
  for (const entry of readdirSync(testsRoot, { recursive: true, encoding: "utf8" })) {
    if (entry === self || entry.includes("node_modules") || !/\.(c|m)?[jt]sx?$/.test(entry)) continue;
    const lines = readFileSync(join(testsRoot, entry), "utf8").split("\n");
    lines.forEach((line, index) => {
      if (forbidden.test(line)) offenders.push(`tests/${entry}:${index + 1}: ${line.trim()}`);
    });
  }
  expect(offenders).toEqual([]);
});
