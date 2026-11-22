// The chat simulator's `--emit-ndjson` (scripts/chat-sim.ts): a scenario becomes a file of acpmux records, and that
// file replayed (`--replay`) draws the same chat, rule for rule. bench/simLogs.ts serves those records to the load
// benches (first-load-after-restart.bench.ts SIM=).
//
// Leo, 2026-11-22: "testing under duress. you should also be able to simulate duress 'offline' aka without a true
// agent thing, just like how i introduced that stuff in the gui."
import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { simChat, simLog } from "../bench/simLogs";
import { parseRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { SCENARIOS, longRun } from "../src/agent-session/acpmux/sim/scenarios";

const webviews = path.resolve(import.meta.dir, "..");
const scratch = mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-sim-emit-"));
afterAll(() => rmSync(scratch, { recursive: true, force: true }));

/** chat-sim's summary line (sim/run.ts `summarize`). */
const SUMMARY =
  /: (\d+) steps, (\d+) rows drawn \((\d+) before folding\).*; violations (.+); mid-turn sibling folds (.+)$/m;

/** Runs chat-sim with `args`: its exit status and the parts of its summary line a replay must match. */
function chatSim(args: string[]) {
  const run = Bun.spawnSync([process.execPath, "scripts/chat-sim.ts", ...args], { cwd: webviews });
  const out = run.stdout.toString();
  const summary = SUMMARY.exec(out);
  if (!summary) throw new Error(`chat-sim ${args.join(" ")} printed no summary:\n${out}${run.stderr.toString()}`);
  const [, steps, rows, recordRows, violations, siblingFolds] = summary;
  return { code: run.exitCode, out, steps, rows, recordRows, violations, siblingFolds };
}

// Every scenario with no reader steps (a scroll is not a record, so a file cannot carry it), and a long run.
const cases: [string, string[], number][] = [
  ...Object.keys(SCENARIOS)
    .filter((name) => SCENARIOS[name]!().steps.every((step) => step.type === "event"))
    .map((name): [string, string[], number] => [name, [name], SCENARIOS[name]!().events.length]),
  ["--long 40", ["--long", "40"], longRun(40).events.length],
];

for (const [label, args, records] of cases)
  test(`chat-sim ${label} --emit-ndjson replays through --replay with the same rows and no violations`, () => {
    const file = path.join(scratch, `${label.replace(/\W+/g, "-")}.ndjson`);
    const emitted = chatSim([...args, "--emit-ndjson", file]);
    expect(emitted.out).toContain(`wrote ${records} records`);
    expect(emitted.out).toContain("--family claude");
    // Read back as `--replay` reads it: every record, in order.
    expect(parseRecords(readFileSync(file, "utf8")).length).toBe(records);
    const replayed = chatSim(["--replay", file, "--family", "claude"]);
    expect({
      code: replayed.code,
      steps: replayed.steps,
      rows: replayed.rows,
      recordRows: replayed.recordRows,
      violations: replayed.violations,
      siblingFolds: replayed.siblingFolds,
    }).toEqual({
      code: 0,
      steps: emitted.steps,
      rows: emitted.rows,
      recordRows: emitted.recordRows,
      violations: "none",
      siblingFolds: emitted.siblingFolds,
    });
    expect(emitted.code).toBe(0);
    expect(Number(replayed.rows)).toBeGreaterThan(0);
  }, 120_000);

test("chat-sim --emit-ndjson needs one scenario", () => {
  const run = Bun.spawnSync(
    [process.execPath, "scripts/chat-sim.ts", "--all", "--emit-ndjson", path.join(scratch, "all.ndjson")],
    { cwd: webviews },
  );
  expect(run.exitCode).toBe(2);
});

test("simLogs: a running long chat is served up to a turn just started, with the rest to stream", () => {
  const log = simLog("long:40", "bench-chat");
  expect(log.records.every((record) => record.sessionId === "bench-chat")).toBe(true);
  const chat = simChat(log, { running: true, restRecords: 120 });
  expect(chat.served.at(-1)!.kind).toBe("turn_started");
  expect(chat.served.length + chat.rest.length).toBe(log.records.length);
  expect(chat.rest.length).toBeGreaterThan(0);
  expect(chat.rest.length).toBeLessThanOrEqual(120);
  expect(chat.turn?.prompt).toStartWith("Turn ");
  // The newest reply before the cut: the turn before the running one says it is done.
  expect(chat.latest).toBe(`Turn ${chat.turns - 1} done.`);
  // A finished chat is served whole, and its newest reply is its last turn's.
  const finished = simChat(log, { running: false, restRecords: 0 });
  expect(finished.rest).toEqual([]);
  expect(finished.latest).toBe("Turn 40 done.");
});

test("simLogs: an emitted file reads back as the scenario's records", () => {
  const file = path.join(scratch, "basic-read.ndjson");
  chatSim(["basic", "--emit-ndjson", file]);
  const read = simLog(file, "bench-chat");
  expect(read.records.map(({ seq, kind }) => [seq, kind])).toEqual(
    SCENARIOS.basic!().events.map(({ seq, kind }) => [seq, kind]),
  );
});
