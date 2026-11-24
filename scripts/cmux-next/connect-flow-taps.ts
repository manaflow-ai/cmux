#!/usr/bin/env bun
// connect-flow-taps: counts the taps and screens a person meets to connect GitHub from a chat
// (GitHub integration audit fixes 5 and 6; "A connect is one inline card, one tap",
// cmuxterm-hq docs/design/remote-integrations.md). It runs the walk in
// webviews/test/github-connect-taps-browser.test.ts (the chat's Connect GitHub card at phone and
// desktop width, a fresh account and one whose installation already covers the repository), prints
// the counts against the budget and the count before the card, and exits non-zero when a walk goes
// over budget. Stills of every card state land in OUT (default: a temp folder).
//
//   bun scripts/cmux-next/connect-flow-taps.ts [OUT]
//   cmux-ci test -- bun scripts/cmux-next/connect-flow-taps.ts   # on a Linux runner with Chromium
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const root = path.resolve(import.meta.dir, "../..");
const out = process.argv[2] ?? process.env.FAST_CHECKS_OUT ?? mkdtempSync(path.join(tmpdir(), "connect-flow-taps-"));
const run = Bun.spawnSync(["bun", "test", "--timeout", "600000", "./test/github-connect-taps-browser.test.ts"], {
  cwd: path.join(root, "webviews"),
  env: { ...process.env, FAST_CHECKS_OUT: out },
  stdout: "inherit",
  stderr: "inherit",
});

type Count = { taps: number; screens: number };
let counts: Record<string, Count> = {};
try {
  counts = JSON.parse(readFileSync(path.join(out, "github-connect", "taps.json"), "utf8"));
} catch {
  console.error(`connect-flow-taps: no counts in ${out}/github-connect/taps.json (the walk did not run)`);
}
const before = counts.before;
for (const [walk, count] of Object.entries(counts)) {
  if (walk === "before") continue;
  console.log(`${walk}: ${count.taps} tap(s), ${count.screens} screen(s)${before ? ` (before the card: ${before.taps} taps, ${before.screens} screens)` : ""}`);
}
console.log(`connect-flow-taps: stills in ${path.join(out, "github-connect")}`);
process.exit(run.exitCode ?? 1);
