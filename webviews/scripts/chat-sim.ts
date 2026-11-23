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
//   bun scripts/chat-sim.ts --sweep ~/.acpmux/sessions [--jobs 4]   (replay every chat there, grouped)
//
// Exit status: 0 with no violations, 1 with any (2: bad arguments).
import { readFileSync, writeFileSync, appendFileSync } from "node:fs";
import { runSimulation, summarize, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { sanitizeRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, type SimScenario } from "../src/agent-session/acpmux/sim/script";
import { SCENARIOS, longRun, scenarioNames } from "../src/agent-session/acpmux/sim/scenarios";
import { cutRecords, readRecords } from "./chat-sim-records";

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
      .slice(1, 16)
      .map((line) => line.replace(/^\/\/ ?/, ""))
      .join("\n"),
  );
  process.exit(code);
}

if (flag("--help") || flag("-h")) usage(0);

/// The class a violation belongs to across chats: its rule and its detail with the row ids, turn
/// numbers, times and quoted text taken out, the gaps kept ("user opens turn N 16px under assistant
/// <id> (want >= 24)").
const violationClass = (violation: { rule: string; detail: string }) =>
  `${violation.rule} ${violation.detail
    .replace(/: ".*$/, "")
    .replace(/\b[a-zA-Z]+-[\w.-]*\d[\w.-]*/g, "<id>")
    .replace(/\bturn \d+/g, "turn N")
    .replace(/\d+ ms\b/g, "N ms")}`;

const sweep = value("--sweep");
if (sweep) {
  // Every chat in the folder (each a session directory with events/), replayed in its own process
  // (a chat's records can be gigabytes), `--jobs` at a time; then one line per violation class: how
  // many rows broke it, in how many chats, and one place to look.
  const root = sweep.replace(/^~/, process.env.HOME ?? "~");
  const chats = readdirSync(root)
    .map((name) => join(root, name))
    .filter((dir) => existsSync(join(dir, "events")));
  const jobs = Math.max(1, number("--jobs") ?? 4);
  const classes = new Map<string, { rows: number; chats: Set<string>; example: string }>();
  let done = 0;
  let failed = 0;
  const runOne = async (dir: string) => {
    const child = Bun.spawn(["bun", import.meta.path, "--replay", dir, "--violations-json"], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const out = await new Response(child.stdout).text();
    await child.exited;
    done += 1;
    const line = out.split("\n").find((text) => text.startsWith("{"));
    if (!line) {
      failed += 1;
      return;
    }
    const chat = dir.split("/").at(-1)!;
    for (const violation of JSON.parse(line).violations as {
      rule: string;
      detail: string;
      step: number;
      rowId: string;
    }[]) {
      const key = violationClass(violation);
      const entry = classes.get(key) ?? { rows: 0, chats: new Set(), example: "" };
      entry.rows += 1;
      entry.chats.add(chat);
      entry.example ||= `--replay ${dir}: step ${violation.step}, ${violation.rowId}`;
      classes.set(key, entry);
    }
    if (done % 20 === 0) console.error(`${done}/${chats.length} chats replayed`);
  };
  const queue = [...chats];
  await Promise.all(
    Array.from({ length: jobs }, async () => {
      for (let dir = queue.shift(); dir; dir = queue.shift()) await runOne(dir);
    }),
  );
  console.log(`swept ${chats.length} chats in ${root}${failed ? ` (${failed} did not finish)` : ""}`);
  for (const [key, entry] of [...classes].sort((a, b) => b[1].chats.size - a[1].chats.size || b[1].rows - a[1].rows))
    console.log(
      `${String(entry.rows).padStart(6)} rows ${String(entry.chats.size).padStart(4)} chats  ${key}\n${" ".repeat(19)}e.g. ${entry.example}`,
    );
  process.exit(classes.size ? 1 : 0);
}
if (flag("--list")) {
  for (const name of scenarioNames()) console.log(`${name.padEnd(24)} ${SCENARIOS[name]!().about}`);
  console.log(`${"--long N".padEnd(24)} N turns of mixed work (about 12 rows a turn)`);
  process.exit(0);
}

const scenarios: SimScenario[] = [];
const replay = value("--replay");
if (replay) {
  const range = { from: number("--from"), to: number("--to"), limit: number("--limit") };
  const raw = readRecords(replay);
  const sanitizeTo = value("--sanitize");
  if (sanitizeTo) {
    const clean = sanitizeRecords(raw, range);
    writeFileSync(sanitizeTo, clean.map((record) => JSON.stringify(record)).join("\n") + "\n");
    console.log(`wrote ${clean.length} sanitized records (of ${raw.length}) to ${sanitizeTo}`);
    scenarios.push(replayScenario(`replay:${sanitizeTo}`, clean));
  } else {
    const kept = cutRecords(raw, range);
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
  if (flag("--violations-json")) {
    // One row per rule it broke (its first step), for `--sweep`.
    const first = new Map<string, (typeof result.violations)[number]>();
    for (const violation of result.violations) {
      const key = `${violation.rule} ${violation.rowId}`;
      if (!first.has(key)) first.set(key, violation);
    }
    console.log(JSON.stringify({ scenario: scenario.name, violations: [...first.values()] }));
    continue;
  }
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
