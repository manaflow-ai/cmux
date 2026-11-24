// l10n-allow-file: test fixture prompts, commands and subagent names, not shipped UI.
// Harness events that arrive after a steer are tool-call work, not standalone rows. Leo, 2026-11-24,
// on a chat that drew "Subagent disconnected: <task> > 1h 14m 51s" a dozen times and "36 background
// commands finished" after the person's steer: "we can initiate the Worked for with these background
// tasks as actual tool calls. we can indeed treat them as tool calls, even though they're bursted at
// the end/start of turns. thereby we can have them be folded properly too."
// Gallery: agent-pane.steered-harness-events.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { backgroundRunRowId } from "./backgroundRuns";
import { turnView, WORKED } from "./turns";

// Put back exactly what was there: the key itself, when the file found none (test/support/leakDetector.ts).
const hadExperiments = "cmuxExperiments" in globalThis;
const previousExperiments = globalThis.cmuxExperiments;
beforeAll(() => {
  globalThis.cmuxExperiments = { "claude-turn-fold": "runs" };
});
afterAll(() => {
  if (hadExperiments) globalThis.cmuxExperiments = previousExperiments;
  else delete globalThis.cmuxExperiments;
});

const START = Date.UTC(2026, 10, 24, 1, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const ended = (index: number, state: string): AcpmuxRow =>
  row(`subagentDone:a${index}`, "subagentDone", 400 + index, {
    subagents: [
      {
        id: `a${index}`,
        parent: null,
        name: `helper-${index}`,
        task: `Check lane ${index}`,
        state,
        startedAt: START,
        endedAt: START + 400_000 + index,
      } as never,
    ],
  });
const shell = (index: number): AcpmuxRow =>
  row(`bg-${index}`, "backgroundTask", 500 + index, {
    backgroundTask: { toolCallId: `bg-${index}`, command: `wait ${index}`, state: "completed", ownerTitle: "helper" },
  });
const work = row("t-1", "activity", 1, {
  items: [{ kind: "tool", text: "", tool: { id: "c1", title: "bun test", kind: "execute", status: "completed" } }],
});

/// A prompt, work, the person's steer, the agent's reply, then the harness's burst.
const steered = (burst: AcpmuxRow[]): AcpmuxRow[] => [
  row("u-0", "user", 0, { text: "Land the lanes" }),
  work,
  row("s-1", "user", 100, { text: "Also check lane 9", steer: "landed" }),
  row("a-1", "assistant", 300, { text: "Checked; lane 9 is green." }),
  row("sum", "turnSummary", 310, { status: "completed", durationMs: 310_000, toolCount: 1 }),
  ...burst,
];
const view = (rows: AcpmuxRow[], expanded: ReadonlySet<string> = new Set()) =>
  turnView(rows, expanded, { agentFamily: "claude", now: START + 900_000 }).filter((r) => r.kind !== "date");
const ids = (rows: AcpmuxRow[]) => rows.map((r) => r.id);

test("a burst of subagent ends after a steer draws no row of its own beside the fold", () => {
  const rows = steered(Array.from({ length: 12 }, (_, i) => ended(i, "disconnected")));
  const closed = view(rows);
  expect(ids(closed).filter((id) => id.startsWith("subagentDone:"))).toEqual([]);
  // The steer stays where it was, a fixed point.
  expect(ids(closed).indexOf("s-1")).toBeGreaterThan(ids(closed).indexOf("u-0"));
  const folds = closed.filter((r) => r.kind === WORKED || r.backgroundRun);
  expect(folds.length).toBeGreaterThan(0);
});

test("the run reads as one count of subagents, and opens to each end", () => {
  const rows = steered(Array.from({ length: 12 }, (_, i) => ended(i, "disconnected")));
  const line = view(rows).find((r) => r.backgroundRun);
  expect(line?.backgroundRun).toMatchObject({ subagents: 12, subagentEnd: "disconnected", other: 0 });
  const html = renderToStaticMarkup(<BackgroundTurnLine row={line!} expanded={false} onToggle={() => {}} />);
  expect(html).toContain("12 subagents disconnected");
  const open = view(rows, new Set([line!.id]));
  expect(ids(open).filter((id) => id.startsWith("subagentDone:"))).toHaveLength(12);
});

test("ends that differ read as one count, and a failed one stays counted", () => {
  const rows = steered([ended(0, "completed"), ended(1, "cancelled"), ended(2, "failed"), shell(3), shell(4)]);
  const line = view(rows).find((r) => r.backgroundRun);
  expect(line?.backgroundRun).toMatchObject({ subagents: 3, commands: 2, failed: 1 });
});

test("the person's steer is never folded or moved by the burst", () => {
  const rows = steered([...Array.from({ length: 5 }, (_, i) => ended(i, "cancelled")), shell(5), shell(6)]);
  const shown = ids(view(rows));
  expect(shown).toContain("s-1");
  expect(shown.indexOf("u-0")).toBeLessThan(shown.indexOf("s-1"));
  expect(backgroundRunRowId).toBeDefined();
});
