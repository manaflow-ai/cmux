#!/usr/bin/env bun
// The chat simulator's command line (src/agent-session/acpmux/sim/README.md). Runs a scripted
// scenario, a replay of a recorded chat, or a long run through the pane's real reducer, turn view
// and layout on virtual time, checks the spacing and fold rules at every step, and writes a JSONL
// trace (one line per step).
//
//   bun scripts/chat-sim.ts --list
//   bun scripts/chat-sim.ts incoming-notice-turn --trace /tmp/sim.jsonl
//   bun scripts/chat-sim.ts --all
//   bun scripts/chat-sim.ts --long 1000 --trace /tmp/long.jsonl
//   bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> [--from SEQ --to SEQ --limit N]
//   bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --sanitize out.ndjson   (a fixture safe to commit)
//   bun scripts/chat-sim.ts --replay test/fixtures/chat-sim/<name>.ndjson
//
// Exit status: 0 with no violations, 1 with any (2: bad arguments).
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { runSimulation, summarize, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { parseRecords, sanitizeRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, type SimScenario } from "../src/agent-session/acpmux/sim/script";
import { SCENARIOS, longRun, scenarioNames } from "../src/agent-session/acpmux/sim/scenarios";

const args = process.argv.slice(2);
const flag = (name: string) => args.includes(name);
const value = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const number = (name: string) => (value(name) === undefined ? undefined : Number(value(name)));

function usage(code: number): never {
  console.log(
    readFileSync(import.meta.path, "utf8")
      .split("\n")
      .slice(1, 15)
      .map((line) => line.replace(/^\/\/ ?/, ""))
      .join("\n"),
  );
  process.exit(code);
}

/** A session directory's records (events/*.ndjson), or one NDJSON file's. */
function readRecords(path: string): EventRecord[] {
  if (statSync(path).isDirectory()) {
    const dir = existsSync(join(path, "events")) ? join(path, "events") : path;
    return readdirSync(dir)
      .filter((name) => name.endsWith(".ndjson"))
      .sort()
      .flatMap((name) => parseRecords(readFileSync(join(dir, name), "utf8")));
  }
  return parseRecords(readFileSync(path, "utf8"));
}

if (flag("--help") || flag("-h")) usage(0);
if (flag("--list")) {
  for (const name of scenarioNames()) console.log(`${name.padEnd(24)} ${SCENARIOS[name]!().about}`);
  console.log(`${"--long N".padEnd(24)} N turns of mixed work (about 12 rows a turn)`);
  process.exit(0);
}

const scenarios: SimScenario[] = [];
const replay = value("--replay");
if (replay) {
  const range = { from: number("--from"), to: number("--to"), limit: number("--limit") };
  const raw = readRecords(replay.replace(/^~/, process.env.HOME ?? "~"));
  const sanitizeTo = value("--sanitize");
  if (sanitizeTo) {
    const clean = sanitizeRecords(raw, range);
    writeFileSync(sanitizeTo, clean.map((record) => JSON.stringify(record)).join("\n") + "\n");
    console.log(`wrote ${clean.length} sanitized records (of ${raw.length}) to ${sanitizeTo}`);
    scenarios.push(replayScenario(`replay:${sanitizeTo}`, clean));
  } else {
    const kept = raw
      .filter((record) => record.seq >= (range.from ?? 0) && record.seq <= (range.to ?? Number.POSITIVE_INFINITY))
      .slice(0, range.limit ?? Number.POSITIVE_INFINITY);
    scenarios.push(replayScenario(`replay:${replay}`, kept));
  }
} else if (value("--long")) {
  scenarios.push(longRun(Number(value("--long"))));
} else if (flag("--all")) {
  for (const name of scenarioNames()) scenarios.push(SCENARIOS[name]!());
} else {
  const name = args.find((arg) => !arg.startsWith("--"));
  if (!name || !SCENARIOS[name]) usage(2);
  scenarios.push(SCENARIOS[name]!());
}

const tracePath = value("--trace");
if (tracePath) writeFileSync(tracePath, "");
const results: SimResult[] = [];
for (const scenario of scenarios) {
  const result = runSimulation(scenario, {
    rowsInTraceUpTo: number("--rows-up-to"),
    onStep: tracePath
      ? (trace) => appendFileSync(tracePath, JSON.stringify({ scenario: scenario.name, ...trace }) + "\n")
      : undefined,
  });
  results.push(result);
  console.log(summarize(result));
  // One line per distinct violation (the same row breaking the same rule at many steps prints once).
  const seen = new Set<string>();
  for (const violation of result.violations) {
    const key = `${violation.rule} ${violation.rowId}`;
    if (seen.has(key)) continue;
    seen.add(key);
    if (seen.size > Number(value("--show") ?? 20)) break;
    console.log(
      `  ${violation.rule.padEnd(16)} step ${violation.step} (+${(violation.at / 1000).toFixed(1)} s, ${violation.label}) ${violation.rowId}: ${violation.detail}`,
    );
  }
}
if (tracePath) console.log(`trace: ${tracePath}`);
process.exit(results.some((result) => result.violations.length) ? 1 : 0);
