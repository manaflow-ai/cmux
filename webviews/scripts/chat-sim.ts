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
//   bun scripts/chat-sim.ts --map   (every mapped case, what is expected of it, and whether it holds)
//   bun scripts/chat-sim.ts --long 1000 --trace /tmp/long.jsonl
//   bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> [--from SEQ --to SEQ --last N --limit N]
//   bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --sanitize out.ndjson   (a fixture safe to commit)
//   bun scripts/chat-sim.ts --replay test/fixtures/chat-sim/<name>.ndjson
//   bun scripts/chat-sim.ts --sweep ~/.acpmux/sessions [--jobs 4]   (replay every chat there, grouped)
//   bun scripts/chat-sim.ts --capture SESSION --window "2:05PM NOV 22 TO 2:11PM" --name leo-2205-x
//   bun scripts/chat-sim.ts --capture SESSION --report "WHY DID IT" [--minutes 6]   (the minutes before that prompt)
//   bun scripts/chat-sim.ts --capture HOST/NAME --window "22:05Z-22:11Z" --out /tmp   (a chat on a peer, over the hub)
//   bun scripts/chat-sim.ts --reported [--update]   (replay each fixture and compare the rows breaking each rule)
//   bun scripts/chat-sim.ts --drift ~/.acpmux/sessions [--days 7 --json]   (record kinds live chats write that no fixture or scenario plays)
//   bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id> --integrity   (bubble-integrity checker only)
//   bun scripts/chat-sim.ts --stream-map [ID...]                           (the stream scenario map, model cases)
//   ... --start-at S | --seek-to-event SEQ [--lead S]   (apply the steps before at once; trace from there)
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
  findReportTurn,
  parseHistory,
  parseTail,
  readAfterSeq,
  REMOTE_SESSION,
  type HistoryTurn,
} from "../src/agent-session/acpmux/sim/capture";
import { readRecords, readReplayRange } from "../src/agent-session/acpmux/sim/records";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { churnSummary, runSimulation, summarize, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { DROPPED, sanitizeRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, type SimScenario } from "../src/agent-session/acpmux/sim/script";
import { replayReported, ruleCounts } from "../src/agent-session/acpmux/sim/reported";
import { EVERYWHERE, MAP } from "../src/agent-session/acpmux/sim/map";
import { seekFromArgs, seekPlan } from "../src/agent-session/acpmux/sim/seek";
import { SCENARIOS, longRun, scenarioNames } from "../src/agent-session/acpmux/sim/scenarios";
import { integrityScan, runMapScenario } from "../src/agent-session/acpmux/sim/mapRun";
import { STREAM_SCENARIOS } from "../src/agent-session/acpmux/sim/streamScenarios";

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
      .split("\nimport ", 1)[0]!
      .split("\n")
      .slice(1)
      .map((line) => line.replace(/^\/\/ ?/, ""))
      .join("\n"),
  );
  process.exit(code);
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

/// The window a capture asks for (`--window`, or the `--minutes` before the `--report` prompt) out of the
/// records it read: a time with no date takes the date of the chat's last record. Exits 2 when there is none.
function captureWindow(records: EventRecord[], from: string, zone: string, minutes: number): [number, number] {
  if (records.length === 0) {
    console.error(`chat-sim: ${from} has no records`);
    process.exit(2);
  }
  const last = records.reduce((most, record) => Math.max(most, record.at), 0);
  const reportText = value("--report");
  if (value("--window")) return windowOf(last, zone, minutes);
  if (reportText !== undefined) {
    const report = findReport(records, reportText);
    if (!report) {
      console.error(`chat-sim: no prompt of the person's in ${from} holds "${reportText}"`);
      process.exit(2);
    }
    return [report.at - minutes * 60_000, report.at];
  }
  console.error("chat-sim: --capture needs --window TIMES or --report TEXT");
  process.exit(2);
}

function windowOf(near: number, zone: string, minutes: number): [number, number] {
  const window = parseWindow(value("--window")!, { zone, near, minutes });
  if (window) return window;
  console.error(
    `chat-sim: cannot read the window "${value("--window")}" (e.g. "2:05PM NOV 22 TO 2:11PM", "22:05Z-22:11Z")`,
  );
  process.exit(2);
}

function localCapture(source: string, zone: string, minutes: number) {
  const { records, from } = sessionRecords(source);
  return { records, from, window: captureWindow(records, from, zone, minutes) };
}

/** How long one acpmux read over the hub may take (`--timeout S`, default 120 for the history, 600 for the tail). */
const hubTimeout = (fallback: number) => (number("--timeout") ?? fallback) * 1000;

/// One line naming the hub's error, then exit 2: no retry, a relay-only host fails every read the same way.
function hubFailed(source: string, detail: string): never {
  console.error(
    `chat-sim: cannot read ${source} over the mesh hub: ${detail.trim().split("\n")[0] || "no answer"}. ` +
      "A host listed only via relay fails every read until cmux#48249; capture on that host instead.",
  );
  process.exit(2);
}

/// `acpmux ARGS` read whole, inside `ms`; its stdout, or hubFailed with its stderr.
async function acpmuxRead(source: string, args: string[], ms: number): Promise<string> {
  const child = Bun.spawn(["acpmux", ...args], { stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  const timer = setTimeout(() => child.kill(), ms);
  const [text, errors] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
  const code = await child.exited;
  clearTimeout(timer);
  if (child.signalCode) hubFailed(source, `acpmux ${args.slice(0, 2).join(" ")} gave no answer in ${ms / 1000} s`);
  if (code !== 0) hubFailed(source, errors);
  return text;
}

/// The records after seq `after`, from `acpmux session tail --json --since`, read as they stream in and
/// stopped at the first record past `until` (the tail itself would read on to the log's end).
async function tailRecords(source: string, after: number, until: number, ms: number): Promise<EventRecord[]> {
  const child = Bun.spawn(["acpmux", "session", "tail", source, "--json", "--since", String(after)], {
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill();
  }, ms);
  const errors = new Response(child.stderr).text();
  const out: EventRecord[] = [];
  const decoder = new TextDecoder();
  let rest = "";
  let past = false;
  for await (const chunk of child.stdout as unknown as AsyncIterable<Uint8Array>) {
    rest += decoder.decode(chunk, { stream: true });
    const cut = rest.lastIndexOf("\n");
    if (cut < 0) continue;
    for (const record of parseTail(rest.slice(0, cut))) {
      if (record.at > until) {
        past = true;
        break;
      }
      out.push(record);
    }
    rest = rest.slice(cut + 1);
    if (past) break;
  }
  if (!past) for (const record of parseTail(rest)) if (record.at <= until) out.push(record);
  if (past) child.kill();
  const code = await child.exited;
  clearTimeout(timer);
  if (timedOut) hubFailed(source, `acpmux session tail gave no answer in ${ms / 1000} s (${out.length} records read)`);
  if (!past && code !== 0) hubFailed(source, await errors);
  return out;
}

/// A chat on a peer (`HOST/NAME`), over the hub: its turn history places the window, then the tail reads from
/// the prompt of the turn running when the window opened to the window's end.
async function remoteCapture(source: string, zone: string, minutes: number) {
  let turns: HistoryTurn[];
  try {
    turns = parseHistory(await acpmuxRead(source, ["session", "history", source, "--json"], hubTimeout(120)));
  } catch (error) {
    hubFailed(source, `its history did not read (${(error as Error).message})`);
  }
  const near = turns.reduce((most, turn) => Math.max(most, turn.endedAt ?? turn.startedAt), 0) || Date.now();
  let window: [number, number];
  const reportText = value("--report");
  if (value("--window")) window = windowOf(near, zone, minutes);
  else if (reportText) {
    const turn = findReportTurn(turns, reportText);
    if (!turn) {
      console.error(`chat-sim: no prompt in ${source}'s history starts with "${reportText}"`);
      process.exit(2);
    }
    window = [turn.startedAt - minutes * 60_000, turn.startedAt];
  } else {
    console.error("chat-sim: --capture HOST/NAME needs --window TIMES or --report TEXT (from the prompt's start)");
    process.exit(2);
  }
  const after = readAfterSeq(turns, window[0]);
  // A few seconds past the end: a record's time can trail the one before it by a little.
  const records = await tailRecords(source, after, window[1] + 10_000, hubTimeout(600));
  if (reportText) {
    const report = findReport(records, reportText);
    if (report) window = [report.at - minutes * 60_000, report.at];
  }
  return {
    records,
    from: `${source} (acpmux session tail over the hub, ${records.length} records after seq ${after})`,
    window,
  };
}

const fixtureDir = join(import.meta.dir, "..", "test", "fixtures", "chat-sim");

if (flag("--reported")) process.exit(replayReported(fixtureDir, flag("--update")) ? 1 : 0);

const capture = value("--capture");
if (capture) {
  // A reported breakage as a fixture (sim/README.md "Capture a reported breakage"): the window's records,
  // led in from the start of the turn running when it opened, sanitized, written beside the other
  // fixtures, then played whole and as the pane reads it after opening or reconnecting partway.
  const began = performance.now();
  const zone = value("--tz") ?? DEFAULT_ZONE;
  const minutes = number("--minutes") ?? 6;
  const remote =
    REMOTE_SESSION.test(capture) &&
    !existsSync(home(capture)) &&
    !existsSync(join(home("~/.acpmux/sessions"), capture, "events"));
  const { records, from, window } = remote
    ? await remoteCapture(capture, zone, minutes)
    : localCapture(capture, zone, minutes);
  const read = performance.now();
  const range = pickRange(records, window[0], window[1], flag("--no-lead") ? "none" : "turn");
  if (!range) {
    console.error(
      `chat-sim: ${from} has no records between ${clockLabel(window[0], zone)} and ${clockLabel(window[1], zone)}`,
    );
    process.exit(2);
  }
  const clean = sanitizeRecords(records, { from: range.fromSeq, to: range.toSeq });
  const name = value("--name") ?? `capture-${new Date(window[0]).toISOString().slice(0, 16).replace(/[-:T]/g, "")}`;
  const out = home(value("--out") ?? fixtureDir);
  const fixture = join(out, `${name}.ndjson`);
  writeFileSync(fixture, clean.map((record) => JSON.stringify(record)).join("\n") + "\n");
  const hostBuild = [...records]
    .reverse()
    .find((record: EventRecord) => record.kind === "host_started" && record.at <= window[1])?.msg?.hostBuild;
  const metadata = {
    window: [new Date(window[0]).toISOString(), new Date(window[1]).toISOString()],
    zone,
    hostBuild: typeof hostBuild === "string" ? hostBuild : null,
    capturedAt: new Date().toISOString(),
    records: clean.length,
    leadIn: range.leadIn,
    inWindow: range.inWindow,
  };
  const writeMetadata = (expect?: Record<string, number>) =>
    writeFileSync(join(out, `${name}.json`), JSON.stringify({ ...metadata, expect }, null, 2) + "\n");
  // A recapture replaces the previous sidecar even if the whole replay below cannot finish.
  writeMetadata();
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
  const whole = runs.find((run) => run.offset.from === 0)?.violations;
  if (whole) writeMetadata(ruleCounts(whole));
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
  const covered = new Set<string>();
  for (const name of readdirSync(fixtureDir).filter((file) => file.endsWith(".ndjson")))
    for (const record of readRecords(join(fixtureDir, name))) covered.add(`${record.dir} ${record.kind}`);
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
  if (flag("--json")) {
    // For a timer (the fleet's chat-sim-drift pass): the same answer as one JSON object.
    console.log(
      JSON.stringify({
        played: covered.size,
        days,
        chats: chats.length,
        missing: read.map(([key, entry]) => ({
          kind: key,
          records: entry.records,
          chats: entry.chats.size,
          newest: new Date(entry.newest).toISOString(),
          example: [...entry.chats][0],
        })),
        unread: seen.size - read.length,
      }),
    );
    process.exit(read.length ? 1 : 0);
  }
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
if (flag("--map")) {
  // The scenario map (sim/map.ts): each case, what is expected, and whether it holds on this checkout.
  const runs = new Map<string, SimResult>();
  const run = (name: string) => runs.get(name) ?? runs.set(name, runSimulation(SCENARIOS[name]!())).get(name)!;
  const rulesOf = (name: string) => run(name).violations.map((violation) => `${violation.rule}: ${violation.detail}`);
  let wrong = 0;
  for (const entry of MAP) {
    const broken = entry.scenario ? [...(entry.check?.(run(entry.scenario)) ?? []), ...rulesOf(entry.scenario)] : [];
    const state = !entry.scenario ? "not played" : broken.length ? (entry.open ? "open" : "BROKEN") : "holds";
    if (state === "BROKEN" || (state === "holds" && entry.open && entry.check)) wrong += 1;
    console.log(`${state.padEnd(10)} ${entry.id}${entry.scenario ? ` (${entry.scenario})` : ""}`);
    console.log(
      `           when:     ${entry.when}\n           wrong:    ${entry.wrong}\n           expected: ${entry.expected}`,
    );
    if (entry.open) console.log(`           open:     ${entry.open}`);
    if (state !== "holds" || flag("--verbose"))
      for (const line of broken.slice(0, 5)) console.log(`           now:      ${line}`);
  }
  for (const each of EVERYWHERE) {
    const breaks = scenarioNames().filter((name) => each.check(run(name)).length > 0);
    const fresh = breaks.filter((name) => !each.known?.[name]);
    wrong += fresh.length;
    console.log(`${(fresh.length ? "BROKEN" : breaks.length ? "open" : "holds").padEnd(10)} everywhere: ${each.id}`);
    console.log(`           expected: ${each.expected}`);
    for (const name of breaks)
      console.log(`           breaks:   ${name}${each.known?.[name] ? ` (open: ${each.known[name]})` : ""}`);
  }
  const count = (state: (entry: (typeof MAP)[number]) => boolean) => MAP.filter(state).length;
  console.log(
    `${MAP.length} cases: ${count((entry) => !!entry.scenario && !entry.open)} hold, ${count((entry) => !!entry.scenario && !!entry.open)} open, ${count((entry) => !entry.scenario)} not played; ${scenarioNames().length} scenarios; ${EVERYWHERE.length} checks on every scenario`,
  );
  process.exit(wrong ? 1 : 0);
}
// The stream scenario map's model cases (docs/design/chat-stream-scenarios.md); the live ones run in its test.
if (flag("--stream-map")) {
  const ids = args.filter((arg) => !arg.startsWith("--"));
  let failed = 0;
  for (const entry of STREAM_SCENARIOS) {
    if (entry.harness !== "sim" || (ids.length && !ids.includes(entry.id))) continue;
    const findings = runMapScenario(entry);
    if (findings.length) failed += 1;
    console.log(`${findings.length ? "FAIL" : "pass"} ${entry.id.padEnd(28)} ${entry.title}`);
    for (const finding of findings.slice(0, Number(value("--show") ?? 3)))
      console.log(
        `  ${finding.rule.padEnd(22)} step ${finding.step} (${finding.label}) ${finding.rowId}: ${finding.detail}`,
      );
  }
  process.exit(failed ? 1 : 0);
}
if (flag("--list")) {
  for (const name of scenarioNames()) console.log(`${name.padEnd(24)} ${SCENARIOS[name]!().about}`);
  console.log(`${"--long N".padEnd(24)} N turns of mixed work (about 12 rows a turn)`);
  process.exit(0);
}

const scenarios: SimScenario[] = [];
const replay = value("--replay");
if (replay) {
  const last = number("--last");
  if (flag("--last") && (last === undefined || !Number.isSafeInteger(last) || last < 0)) {
    console.error("chat-sim: --last needs a nonnegative integer");
    process.exit(2);
  }
  const {
    records: raw,
    parsed,
    count,
  } = await readReplayRange(home(replay), {
    from: number("--from"),
    to: number("--to"),
    last,
  });
  if (parsed < count) console.error(`parsed ${parsed} of ${count} event files (${raw.length} records in range)`);
  const limit = number("--limit");
  const sanitizeTo = value("--sanitize");
  if (sanitizeTo) {
    const clean = sanitizeRecords(raw, { limit });
    writeFileSync(sanitizeTo, clean.map((record) => JSON.stringify(record)).join("\n") + "\n");
    console.log(`wrote ${clean.length} sanitized records (of ${raw.length}) to ${sanitizeTo}`);
    scenarios.push(replayScenario(`replay:${sanitizeTo}`, clean));
  } else {
    const kept = raw.slice(0, limit);
    scenarios.push(replayScenario(`replay:${replay}`, kept));
  }
} else if (value("--long")) {
  scenarios.push(longRun(Number(value("--long"))));
} else if (flag("--all")) {
  for (const name of scenarioNames()) scenarios.push(SCENARIOS[name]!());
} else {
  const name = args.find((arg, at) => !arg.startsWith("--") && !args[at - 1]?.startsWith("--"));
  if (!name || !SCENARIOS[name]) usage(2);
  scenarios.push(SCENARIOS[name]!());
}

// The bubble-integrity checker on recorded chats: one line a finding, exit 1 on any.
if (flag("--integrity")) {
  let found = 0;
  for (const scenario of scenarios) {
    const findings = integrityScan(scenario);
    found += findings.length;
    console.log(`${scenario.name}: ${scenario.events.length} records, ${findings.length} integrity findings`);
    for (const finding of findings.slice(0, Number(value("--show") ?? 20)))
      console.log(
        `  ${finding.rule.padEnd(24)} step ${finding.step} (${finding.label}) ${finding.rowId}: ${finding.detail}`,
      );
  }
  process.exit(found ? 1 : 0);
}

const tracePath = value("--trace");
if (tracePath) writeFileSync(tracePath, "");
const results: SimResult[] = [];
const seek = seekFromArgs(value);
for (const scenario of scenarios) {
  // A seek still runs every step (the state at the start is exact); the trace and the violations start there.
  const start = seek ? seekPlan(scenario.steps, seek).start : 0;
  if (seek)
    console.log(
      `seek: ${start} steps applied at once, from step ${start} (+${(((scenario.steps[start]?.at ?? 0) - (scenario.steps[0]?.at ?? 0)) / 1000).toFixed(1)} s)`,
    );
  const ran = runSimulation(scenario, {
    rowsInTraceUpTo: number("--rows-up-to"),
    onStep: tracePath
      ? (trace) => {
          if (trace.step >= start)
            appendFileSync(tracePath, JSON.stringify({ scenario: scenario.name, ...trace }) + "\n");
        }
      : undefined,
  });
  const result = start ? { ...ran, violations: ran.violations.filter((violation) => violation.step >= start) } : ran;
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
