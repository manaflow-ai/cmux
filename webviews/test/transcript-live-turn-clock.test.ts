// l10n-allow-file: test fixture text, not shipped UI.
// A running turn as the Codex app and T3 Code draw it (Lucas, 2026-11-11): "Working for 32s" over
// its work, under the prompt, where "Worked for" lands when the turn ends, and a bottom line that
// says only "Thinking", with no clock (conversation/liveTurnClock.experiment.ts).
import { afterEach, expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { THINKING, WORKED, turnView } from "../src/agent-session/acpmux/conversation/turns";

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
  expect(live[1]).toMatchObject({ kind: WORKED, id: "worked-u", turnPhase: "running" });
  expect(live[1]!.below).toBeUndefined();
  expect(live.at(-1)).toMatchObject({ kind: THINKING, below: true, untimed: true });
});

test("the turn's end puts Worked for in Working for's place, at the same height", () => {
  const ended = [...turn, row("end", "turnSummary", 4_000, { status: "completed", durationMs: 4_000 })];
  const live = turnView(turn, new Set(), { now: 60_000, agentFamily: "codex", working: true });
  const done = turnView(ended, new Set(), { now: 60_000, agentFamily: "codex", working: false });
  const header = live.findIndex((each) => each.turnPhase === "running");
  const worked = done.findIndex((each) => each.kind === WORKED);
  const [during, after] = [layoutConversation(live, 720), layoutConversation(done, 720)];
  expect(after.tops[worked]).toBe(during.tops[header]);
  expect(after.heights[worked]).toBe(during.heights[header]);
});

// A reply-only turn's end keeps its Worked for line in this place (turns.ts `holdsHeader`, #51896), so it draws
// Working for from its first row, as every turn does; it once drew none, then the heading arrived with the first
// work row and moved the reply down. Leo, 2026-11-22: "accounting for space for the worked for/working heading should always be there anyways so it disappearing means there's multiple problems".
test("a turn of only a reply so far draws Working for under its prompt, where its end draws Worked for", () => {
  const live = shown(turnView(turn.slice(0, 2), new Set(), { now: 60_000, agentFamily: "codex", working: true }));
  expect(live.map((each) => each.id)).toEqual(["u", "worked-u", "plan", expect.any(String)]);
  expect(live[1]).toMatchObject({ kind: WORKED, turnPhase: "running" });
});

test("the line arm keeps the clock on the bottom line and draws nothing over the work", () => {
  scope.cmuxExperiments = { "live-turn-clock": "line" };
  const live = shown(turnView(turn, new Set(), { now: 60_000, agentFamily: "codex", working: true }));
  expect(live.some((each) => each.turnPhase === "running")).toBe(false);
  expect(live.at(-1)!.untimed).toBeUndefined();
});
