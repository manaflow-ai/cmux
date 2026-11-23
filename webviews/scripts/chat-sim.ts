#!/usr/bin/env bun
// The chat simulator's command line (src/agent-session/acpmux/sim/README.md). Runs a scripted
// scenario, a replay of a recorded chat, or a long run through the pane's real reducer, turn view
// and layout on virtual time, checks the spacing and fold rules at every step, and writes a JSONL
// trace (one line per step).
//
//   bun scripts/chat-sim.ts --list
//   bun scripts/chat-sim.ts incoming-notice-turn --trace /tmp/sim.jsonl
//   bun scripts/chat-sim.ts --all
//   bun scripts/chat-sim.ts churn --churn   (layout shifts and sub-second rows per minute)
//   bun scripts/chat-sim.ts --long 1000 --trace /tmp/long.jsonl
//   bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> [--from SEQ --to SEQ --limit N]
//   bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --sanitize out.ndjson   (a fixture safe to commit)
//   bun scripts/chat-sim.ts --replay test/fixtures/chat-sim/<name>.ndjson
//   bun scripts/chat-sim.ts --sweep ~/.acpmux/sessions [--jobs 4]   (replay every chat there, grouped)
//   bun scripts/chat-sim.ts --capture SESSION --window "2:05PM NOV 22 TO 2:11PM" --name leo-2205-x
//   bun scripts/chat-sim.ts --capture SESSION --report "WHY DID IT" [--minutes 6]   (the minutes before that prompt)
//   bun scripts/chat-sim.ts --drift ~/.acpmux/sessions   (record kinds live chats write that no fixture or scenario plays)
//
// Exit status: 0 with no violations, 1 with any (2: bad arguments).
import { appendFileSync, existsSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  DEFAULT_ZONE,
  clockLabel,
  findReport,
  parseWindow,
  pickRange,
  readOffsets,
} from "../src/agent-session/acpmux/sim/capture";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { churnSummary, runSimulation, summarize, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { DROPPED, parseRecords, sanitizeRecords } from "../src/agent-session/acpmux/sim/sanitize";
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
      .slice(1, 19)
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

const home = (path: string) => path.replace(/^~/, process.env.HOME ?? "~");

/// A session's records wherever it is: a folder or NDJSON file, a session id under ~/.acpmux/sessions, or
/// any name `acpmux session export` resolves (a name, an id, HOST/NAME on a peer), exported to a temp folder.
function sessionRecords(source: string): { records: EventRecord[]; from: string } {
  const path = home(source);
  if (existsSync(path)) return { records: readRecords(path), from: path };
  const local = join(home("~/.acpmux/sessions"), source);
  if (existsSync(join(local, "events"))) return { records: readRecords(local), from: local };
  const dest = mkdtempSync(join(tmpdir(), "chat-sim-capture-"));
  const exported = Bun.spawnSync(["acpmux", "session", "export", source, "--dest", dest], { stderr: "pipe" });
  const dir = existsSync(dest) ? readdirSync(dest).find((name) => existsSync(join(dest, name, "events"))) : undefined;
  if (exported.exitCode !== 0 || !dir) {
    console.error(`chat-sim: no session ${source} here or on a peer: ${exported.stderr.toString().trim()}`);
    process.exit(2);
  }
  return { records: readRecords(join(dest, dir)), from: `${source} (acpmux session export)` };
}

const capture = value("--capture");
if (capture) {
  // A reported breakage as a fixture (sim/README.md "Capture a reported breakage"): the window's records,
  // led in from the start of the turn running when it opened, sanitized, written beside the other
  // fixtures, then played whole and as the pane reads it after opening or reconnecting partway.
  const began = performance.now();
  const zone = value("--tz") ?? DEFAULT_ZONE;
  const minutes = number("--minutes") ?? 6;
  const { records, from } = sessionRecords(capture);
  const read = performance.now();
  if (records.length === 0) {
    console.error(`chat-sim: ${from} has no records`);
    process.exit(2);
  }
  const last = records.reduce((most, record) => Math.max(most, record.at), 0);
  let window: [number, number] | undefined;
  const reportText = value("--report");
  if (value("--window")) {
    window = parseWindow(value("--window")!, { zone, near: last, minutes });
    if (!window) {
      console.error(
        `chat-sim: cannot read the window "${value("--window")}" (e.g. "2:05PM NOV 22 TO 2:11PM", "22:05Z-22:11Z")`,
      );
      process.exit(2);
    }
  } else if (reportText !== undefined) {
    const report = findReport(records, reportText);
    if (!report) {
      console.error(`chat-sim: no prompt of the person's in ${from} holds "${reportText}"`);
      process.exit(2);
    }
    window = [report.at - minutes * 60_000, report.at];
  } else {
    console.error("chat-sim: --capture needs --window TIMES or --report TEXT");
    process.exit(2);
  }
  const range = pickRange(records, window[0], window[1], flag("--no-lead") ? "none" : "turn");
  if (!range) {
    console.error(
      `chat-sim: ${from} has no records between ${clockLabel(window[0], zone)} and ${clockLabel(window[1], zone)}`,
    );
    process.exit(2);
  }
  const clean = sanitizeRecords(records, { from: range.fromSeq, to: range.toSeq });
  const name = value("--name") ?? `capture-${new Date(window[0]).toISOString().slice(0, 16).replace(/[-:T]/g, "")}`;
  const out = home(value("--out") ?? join(import.meta.dir, "..", "test", "fixtures", "chat-sim"));
  const fixture = join(out, `${name}.ndjson`);
  writeFileSync(fixture, clean.map((record) => JSON.stringify(record)).join("\n") + "\n");
  const hostBuild = [...records]
    .reverse()
    .find((record: EventRecord) => record.kind === "host_started" && record.at <= window[1])?.msg?.hostBuild;
  writeFileSync(
    join(out, `${name}.json`),
    JSON.stringify(
      {
        window: [new Date(window[0]).toISOString(), new Date(window[1]).toISOString()],
        zone,
        hostBuild: typeof hostBuild === "string" ? hostBuild : null,
        capturedAt: new Date().toISOString(),
        records: clean.length,
        leadIn: range.leadIn,
        inWindow: range.inWindow,
      },
      null,
      2,
    ) + "\n",
  );
  const written = performance.now();
  console.log(
    `captured ${clockLabel(window[0], zone)} to ${clockLabel(window[1], zone)} from ${from}: ` +
      `${clean.length} records (${range.inWindow} in the window, ${range.leadIn} leading in from its turn's start) -> ${fixture}`,
  );
  // Each read of it in its own process at once: the answer for every read takes the time of the longest.
  const offsets = readOffsets(clean.length);
  const runs = await Promise.all(
    offsets.map(async (offset) => {
      const child = Bun.spawn(
        ["bun", import.meta.path, "--replay", fixture, "--from", String(offset.from + 1), "--violations-json"],
        { stdout: "pipe", stderr: "ignore" },
      );
      const text = await new Response(child.stdout).text();
      await child.exited;
      const line = text.split("\n").find((row) => row.startsWith("{"));
      return {
        offset,
        violations: line
          ? (JSON.parse(line).violations as { rule: string; step: number; at: number; rowId: string; detail: string }[])
          : undefined,
      };
    }),
  );
  const realFirst = records.find((record) => record.seq === range.fromSeq)!.at;
  for (const run of runs) {
    if (!run.violations) {
      console.log(`  ${run.offset.name.padEnd(26)} did not finish`);
      continue;
    }
    const byRule = new Map<string, number>();
    for (const violation of run.violations) byRule.set(violation.rule, (byRule.get(violation.rule) ?? 0) + 1);
    console.log(
      `  ${run.offset.name.padEnd(26)} ${run.violations.length ? [...byRule].map(([rule, n]) => `${rule} ${n}`).join(", ") : "clean"}`,
    );
    for (const violation of run.violations.slice(0, Number(value("--show") ?? 3)))
      console.log(
        `    ${violation.rule} at ${clockLabel(realFirst + (clean[run.offset.from]!.at - clean[0]!.at) + violation.at, zone)} step ${violation.step} ${violation.rowId}: ${violation.detail}`,
      );
  }
  const ended = performance.now();
  console.log(
    `took ${((ended - began) / 1000).toFixed(1)} s (read ${((read - began) / 1000).toFixed(1)} s, write ${((written - read) / 1000).toFixed(1)} s, ` +
      `${offsets.length} reads played ${((ended - written) / 1000).toFixed(1)} s). Replay it: bun scripts/chat-sim.ts --replay ${fixture} --trace /tmp/${name}.jsonl`,
  );
  console.log("Look it over (grep it for names and hosts) before committing it.");
  process.exit(0);
}

const drift = value("--drift");
if (drift) {
  // What the offline simulator does not play: record kinds the chats here wrote that no committed fixture
  // and no scenario holds, and that the sanitizer does not drop as noise. One line each, most written first.
  const fixtures = join(import.meta.dir, "..", "test", "fixtures", "chat-sim");
  const covered = new Set<string>();
  for (const name of readdirSync(fixtures).filter((file) => file.endsWith(".ndjson")))
    for (const record of readRecords(join(fixtures, name))) covered.add(`${record.dir} ${record.kind}`);
  for (const name of scenarioNames())
    for (const record of SCENARIOS[name]!().events) covered.add(`${record.dir} ${record.kind}`);
  const seen = new Map<string, { records: number; chats: Set<string>; newest: number }>();
  const root = home(drift);
  const chats = existsSync(join(root, "events"))
    ? [root]
    : readdirSync(root)
        .map((name) => join(root, name))
        .filter((dir) => existsSync(join(dir, "events")));
  const since = Date.now() - (number("--days") ?? 7) * 86_400_000;
  for (const chat of chats) {
    if (statSync(join(chat, "events")).mtimeMs < since) continue;
    for (const record of readRecords(chat)) {
      if (record.at < since || record.dir === "out" || DROPPED.has(record.kind)) continue;
      const key = `${record.dir} ${record.kind}`;
      if (covered.has(key)) continue;
      const entry = seen.get(key) ?? { records: 0, chats: new Set(), newest: 0 };
      entry.records += 1;
      entry.chats.add(chat);
      entry.newest = Math.max(entry.newest, record.at);
      seen.set(key, entry);
    }
  }
  // The kinds the pane reads: those its source names as a string ("queued", "steer_read"). The rest are
  // a harness's own stream (codex.hook/started), which the pane never branches on.
  const paneSource = (dir: string): string =>
    readdirSync(dir, { withFileTypes: true })
      .map((entry) => {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) return entry.name === "sim" ? "" : paneSource(path);
        return /\.tsx?$/.test(entry.name) && !/\.(test|gallery)\.tsx?$/.test(entry.name)
          ? readFileSync(path, "utf8")
          : "";
      })
      .join("\n");
  const source = paneSource(join(import.meta.dir, "..", "src", "agent-session"));
  const read = [...seen].filter(([key]) => source.includes(`"${key.split(" ")[1]}"`));
  const days = number("--days") ?? 7;
  console.log(
    `${covered.size} record kinds played offline. Chats here in the last ${days} days wrote ${read.length} more that the pane reads ` +
      `and the simulator never plays (and ${seen.size - read.length} the pane does not read; --all-kinds lists them):`,
  );
  for (const [key, entry] of (flag("--all-kinds") ? [...seen] : read).sort(
    (a, b) => b[1].chats.size - a[1].chats.size || b[1].records - a[1].records,
  ))
    console.log(
      `${String(entry.records).padStart(7)} records ${String(entry.chats.size).padStart(4)} chats  ${key.padEnd(40)} newest ${new Date(entry.newest).toISOString().slice(0, 16)}Z  e.g. ${[...entry.chats][0]}`,
    );
  if (read.length) {
    // The window that would cover the most of them at once: in each chat, every `--minutes` long window
    // that opens at a record of a missing kind, counted by the missing kinds it holds.
    const missing = new Set(read.map(([key]) => key));
    const span = (number("--minutes") ?? 10) * 60_000;
    let best: { chat: string; start: number; kinds: Set<string> } | undefined;
    for (const chat of new Set(read.flatMap(([, entry]) => [...entry.chats]))) {
      const hits = readRecords(chat)
        .filter((record) => record.at >= since && missing.has(`${record.dir} ${record.kind}`))
        .sort((a, b) => a.at - b.at);
      for (let first = 0, last = 0; first < hits.length; first += 1) {
        while (last < hits.length && hits[last]!.at - hits[first]!.at <= span) last += 1;
        const kinds = new Set(hits.slice(first, last).map((record) => `${record.dir} ${record.kind}`));
        if (!best || kinds.size > best.kinds.size) best = { chat, start: hits[first]!.at, kinds };
      }
    }
    if (best)
      console.log(
        `The window covering the most of them (${best.kinds.size}): bun scripts/chat-sim.ts --capture ${best.chat} ` +
          `--window "${new Date(best.start).toISOString()} to ${new Date(best.start + span).toISOString()}" --name NAME`,
      );
    console.log("Or add a kind to a scenario (script.ts record()).");
  }
  process.exit(read.length ? 1 : 0);
}

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
  if (flag("--churn")) {
    // Layout shifts and sub-second rows per minute of churn, and each one (`--show N` at most).
    console.log(`  churn ${churnSummary(result)}`);
    const show = Number(value("--show") ?? 20);
    for (const shift of result.shifts.slice(0, show))
      console.log(
        `  shift ${shift.phase.padEnd(8)} step ${shift.step} (+${(shift.at / 1000).toFixed(1)} s, ${shift.label}) moved ${shift.moved} rows up to ${shift.px}px, back ${shift.back}px; cause ${shift.cause}`,
      );
    for (const flash of result.flashes.slice(0, show))
      console.log(
        `  flash ${flash.phase.padEnd(8)} step ${flash.step} (+${(flash.at / 1000).toFixed(1)} s, ${flash.label}) ${flash.kind} ${flash.id} shown ${flash.shownMs} ms`,
      );
  }
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
