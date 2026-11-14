// l10n-allow-file: test fixture text, not shipped UI.
// A running turn as the Codex app and T3 Code draw it (Lucas, 2026-11-11): "Working for 32s" over
// its work, under the prompt, where "Worked for" lands when the turn ends, and a bottom line that
// says only "Thinking", with no clock (conversation/liveTurnClock.experiment.ts).
import { afterEach, expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ACTIVITY_LINE, THINKING, WORKED, WORKING, turnView } from "../src/agent-session/acpmux/conversation/turns";

const scope = globalThis as { cmuxExperiments?: Record<string, string> };
afterEach(() => {
  delete scope.cmuxExperiments;
});

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const call = (id: string, at: number) =>
  row(id, "activity", at, {
    items: [
      { kind: "tool", text: "ls", tool: { id, kind: "execute", title: "ls", command: "ls", status: "completed" } },
    ],
  });
const turn = [
  row("u", "user", 0, { text: "Build the page" }),
  row("plan", "assistant", 1_000, { text: "I'll check the project first." }),
  call("c1", 2_000),
  row("note", "assistant", 3_000, { text: "Now the layout." }),
];
const shown = (rows: AcpmuxRow[]) => rows.filter((each) => each.kind !== "date");

test("a running turn with work draws Working for under its prompt, and the bottom line has no clock", () => {
  const live = shown(turnView(turn, new Set(), { now: 60_000, agentFamily: "codex", working: true }));
  expect(live[0]!.id).toBe("u");
  expect(live[1]).toMatchObject({ kind: WORKING, id: "working-u" });
  expect(live[1]!.below).toBeUndefined();
  expect(live.at(-1)).toMatchObject({ kind: THINKING, below: true, untimed: true });
});

test("the turn's end puts Worked for in Working for's place, at the same height", () => {
  const ended = [...turn, row("end", "turnSummary", 4_000, { status: "completed", durationMs: 4_000 })];
  const live = turnView(turn, new Set(), { now: 60_000, agentFamily: "codex", working: true });
  const done = turnView(ended, new Set(), { now: 60_000, agentFamily: "codex", working: false });
  const header = live.findIndex((each) => each.kind === WORKING);
  const worked = done.findIndex((each) => each.kind === WORKED);
  const [during, after] = [layoutConversation(live, 720), layoutConversation(done, 720)];
  expect(after.tops[worked]).toBe(during.tops[header]);
  expect(after.heights[worked]).toBe(during.heights[header]);
});

test("a turn of only a reply so far draws no Working for: its end has no fold line to take its place", () => {
  const live = shown(turnView(turn.slice(0, 2), new Set(), { now: 60_000, agentFamily: "codex", working: true }));
  expect(live.some((each) => each.kind === WORKING)).toBe(false);
});

test("a plan's activity line replaces the top clock when session status is enabled", () => {
  const plan = row("steps", "plan", 4_000, { plan: [{ content: "Build", status: "in_progress" }] });
  const rows = [...turn.slice(0, -1), plan];
  const options = { now: 60_000, agentFamily: "codex", working: true };
  expect(turnView(rows, new Set(), options).some((each) => each.kind === WORKING)).toBe(true);
  const status = turnView(rows, new Set(), { ...options, sessionStatus: true });
  expect(status.at(-1)?.kind).toBe(ACTIVITY_LINE);
  expect(status.some((each) => each.kind === WORKING)).toBe(false);
});

test("the line arm keeps the clock on the bottom line and draws nothing over the work", () => {
  scope.cmuxExperiments = { "live-turn-clock": "line" };
  const live = shown(turnView(turn, new Set(), { now: 60_000, agentFamily: "codex", working: true }));
  expect(live.some((each) => each.kind === WORKING)).toBe(false);
  expect(live.at(-1)!.untimed).toBeUndefined();
});
