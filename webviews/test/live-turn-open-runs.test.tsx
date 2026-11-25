// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A running turn folds nothing (liveTurnWork.experiment.ts `open`, the default). Leo, 2026-11-21
// 05:47Z, on a running turn whose runs folded into "Ran 4 commands, used 2 tools, received 4
// messages" and "Ran 10 commands and used a tool" around his steer: "why are you folding these after
// my message while you're in teh middle of a turn? i thought we dont fold while you're still going.
// but my steers affect these. they shouldn't be like this. it's fucking weird. the behaiour is odd."
//
// - While the turn runs, every finished call keeps its own line: no run is a folded run (`foldRun`)
//   and no message run folds them, before a steer, after it, and after more calls.
// - A steer changes nothing drawn above it: the run before it is the same rows, drawn the same.
// - Once the turn ends, its work folds under "Worked for" as it did under `runs`.
// The `runs` arm (each finished run folded mid-turn) is transcript-live-runs.test.tsx's.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { MESSAGE_RUN, type AcpmuxActivity, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";
import { liveTurnWork } from "../src/agent-session/acpmux/conversation/liveTurnWork.experiment";
import { experimentArm } from "../src/experiments/experiment";

const armsBefore = globalThis.cmuxExperiments;
afterEach(() => {
  globalThis.cmuxExperiments = armsBefore;
});
const pin = (arm: "open" | "runs") => {
  globalThis.cmuxExperiments = { ...armsBefore, "live-turn-work": arm };
};

const START = Date.UTC(2026, 10, 21, 5, 40, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const shell = (id: string, command: string, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: command, kind: "execute", status, command },
});
const read = (id: string, path: string): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: `Read ${path}`, kind: "read", status: "completed", locations: [{ path }] },
});

// Leo's turn: four commands and two reads, a reply, then his steer, then ten more commands and one
// still running. Each step is its own record, so each is a row object the next record keeps.
const prompt = row("u-0", "user", 0, { text: "Why does the fold move when I steer?" });
const firstRun = row("t-1", "activity", 1, {
  items: [
    shell("t-1-0", "rg -n foldRun src"),
    shell("t-1-1", "git log -5 --oneline"),
    read("t-1-2", "src/turns.ts"),
    shell("t-1-3", "rg -n codexRuns src"),
    read("t-1-4", "src/toolGroups.ts"),
    shell("t-1-5", "git status"),
  ],
});
const reply = row("a-1", "assistant", 60, { text: "Reading where a running turn folds its runs." });
const secondRun = row("t-2", "activity", 61, {
  items: [shell("t-2-0", "rg -n earlierRun src"), shell("t-2-1", "git diff --stat")],
});
const steer = row("s-1", "user", 120, { text: "Also check what a steer does to them", steer: "landed" });
const afterSteer = row("t-3", "activity", 121, {
  items: [
    ...Array.from({ length: 10 }, (_, at) => shell(`t-3-${at}`, `bun test case-${at}`)),
    shell("t-3-10", "sleep 10", "in_progress"),
  ],
});

const beforeSteer = [prompt, firstRun, reply, secondRun];
const steered = [...beforeSteer, steer];
const going = [...steered, afterSteer];

const live = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true, now: START + 130_000 });
const runsOf = (shaped: AcpmuxRow[]) => shaped.filter((entry) => entry.kind === "activity");
const drawn = (entry: AcpmuxRow) =>
  renderToStaticMarkup(<ToolRows row={entry} />)
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ");
/// What a run draws, by row id: the calls it keeps, whether it folds, and its drawn text.
const shapes = (shaped: AcpmuxRow[]) =>
  Object.fromEntries(
    runsOf(shaped).map((entry) => [
      entry.id,
      { calls: entry.items!.map((item) => item.tool?.id), foldRun: entry.foldRun, text: drawn(entry) },
    ]),
  );

test("open is the shipped arm", () => {
  globalThis.cmuxExperiments = undefined;
  expect(liveTurnWork.defaultArm).toBe("open");
  expect(experimentArm(liveTurnWork, { overrides: {}, stored: {} })).toBe("open");
});

test("a running turn folds no run, before a steer, after it and after more calls", () => {
  pin("open");
  for (const rows of [beforeSteer, steered, going]) {
    const shaped = live(rows);
    expect(runsOf(shaped).length).toBeGreaterThan(0);
    for (const entry of runsOf(shaped)) expect(entry.foldRun).not.toBe(true);
    expect(shaped.some((entry) => entry.kind === MESSAGE_RUN)).toBe(false);
    // No run summary line ("Ran 4 commands, read 2 files"): each call reads on its own line.
    for (const entry of runsOf(shaped)) expect(drawn(entry)).not.toMatch(/Ran \d+ commands, read/);
  }
  const text = drawn(runsOf(live(going)).find((entry) => entry.id === "t-1")!);
  for (const step of [
    "Searched for “foldRun”",
    "Read git history",
    "Read turns.ts",
    "Searched for “codexRuns”",
    "Checked git status",
  ])
    expect(text).toContain(step);
});

test("a steer changes nothing drawn above it", () => {
  pin("open");
  const before = shapes(live(beforeSteer));
  const withSteer = shapes(live(steered));
  const later = shapes(live(going));
  expect(withSteer["t-1"]).toEqual(before["t-1"]);
  expect(withSteer["t-2"]).toEqual(before["t-2"]);
  expect(later["t-1"]).toEqual(before["t-1"]);
  expect(later["t-2"]).toEqual(before["t-2"]);
  // The calls after the steer: the finished ten, not the one in flight, which the live line names.
  expect(later["t-3"]!.calls).toEqual(Array.from({ length: 10 }, (_, at) => `t-3-${at}`));
  expect(later["t-3"]!.foldRun).toBe(false);
  // The rows before the steer keep their order around it.
  expect(
    live(going)
      .map((entry) => entry.id)
      .filter((id) => ["t-1", "a-1", "t-2", "s-1", "t-3"].includes(id)),
  ).toEqual(["t-1", "a-1", "t-2", "s-1", "t-3"]);
});

test("an earlier run is the same object from record to record", () => {
  pin("open");
  const once = runsOf(live(going)).find((entry) => entry.id === "t-2")!;
  const again = runsOf(live([...steered, { ...afterSteer, version: 2 }])).find((entry) => entry.id === "t-2")!;
  expect(again).toBe(once);
  // The `runs` arm's copy of the same run is its own (earlierRuns keys on whether it folds).
  pin("runs");
  const folded = runsOf(live(going)).find((entry) => entry.id === "t-2")!;
  expect(folded).not.toBe(once);
  expect(folded.foldRun).toBe(true);
  pin("open");
  expect(runsOf(live(going)).find((entry) => entry.id === "t-2")!.foldRun).toBe(false);
});

test("under runs, the steer folds the runs before it (the comparison arm)", () => {
  pin("runs");
  const shaped = live(going);
  expect(runsOf(shaped).find((entry) => entry.id === "t-1")?.foldRun).toBe(true);
});

const ended = [
  ...going.slice(0, -1),
  {
    ...afterSteer,
    items: afterSteer.items!.map((item) => ({ ...item, tool: { ...item.tool!, status: "completed" } })),
  },
  row("a-final", "assistant", 200, { text: "A steer no longer regroups the runs above it." }),
  row("s-0", "turnSummary", 210, { status: "completed", durationMs: 210_000, toolCount: 19 }),
];
const endedView = () => turnView(ended, new Set(), { now: START + 300_000 });

test("once the turn ends, its work folds under Worked for", () => {
  pin("open");
  const closed = endedView();
  expect(closed.some((entry) => entry.kind === WORKED)).toBe(true);
  // Closed, no call is drawn at the top level; the replies and the steer stay in sight.
  expect(runsOf(closed)).toEqual([]);
  expect(closed.some((entry) => entry.id === "s-1")).toBe(true);
  expect(closed.some((entry) => entry.id === "a-final")).toBe(true);
});

test("the ended turn draws the same under open and runs", () => {
  const key = (rows: AcpmuxRow[]) => rows.map((entry) => [entry.id, entry.kind, entry.foldRun, entry.version]);
  pin("open");
  const open = key(endedView());
  pin("runs");
  expect(key(endedView())).toEqual(open);
});
