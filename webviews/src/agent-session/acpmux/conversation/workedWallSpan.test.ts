// l10n-allow-file: test fixture tool titles, not shipped UI.
// A finished turn's "Worked for" is the turn's wall span, from its first event to its last: its
// thinking, its model round trips and every tool call's own timeline. It never reads less than the
// footer's Timeline total (Leo, 2026-11-27: "but shouldn't the worked for count the timelines of the
// tool calls"). #42247 ended it at the first final answer, so a call that ran on past the answer
// read "Worked for <1s" over a Timeline of "2 calls · 2.8s".
import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { translate, type Translate } from "../i18n";
import { turnClock, turnView, WORKED, workedLabel } from "./turns";
import { turnWork, waterfall, wallSpan } from "./waterfallSpans";

const t: Translate = (key, values) => translate(key, values, "en");

const row = (id: string, at: number, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  at,
  kind,
  version: 1,
  ...fields,
});

const call = (id: string, from: number, to: number): AcpmuxActivity => ({
  kind: "tool",
  text: `Run ${id}`,
  tool: { id, title: `Run ${id}`, kind: "execute", status: "completed", startedAt: from, endedAt: to },
});

/// Leo's turn: the prompt at 10s, a short thought, the answer at 10.3s, and two calls that ran on to
/// 12.8s; the harness's own record of the turn says it took 300ms.
const outlastingTurn = (): AcpmuxRow[] => [
  row("prompt", 10_000, "user", { text: "Queue the lands" }),
  row("act", 10_010, "activity", {
    items: [
      { kind: "thought", text: "Queue them", startedAt: 10_000, endedAt: 10_003 },
      call("queue", 10_300, 12_500),
      call("send", 10_300, 12_800),
    ],
  }),
  row("answer", 10_300, "assistant", { text: "Queued.", assistantPhase: "final_answer" }),
  row("summary", 10_300, "turnSummary", { status: "completed", toolCount: 2, durationMs: 300, turnStartedAtMs: 10_000 }),
];

test("wallSpan: the earlier of the start and the first span, the later of the end and the last", () => {
  const work = [call("a", 5_000, 9_000), call("b", 2_000, 3_000)];
  expect(wallSpan(4_000, 6_000, work)).toEqual({ start: 2_000, end: 9_000 });
  expect(wallSpan(undefined, undefined, work)).toEqual({ start: 2_000, end: 9_000 });
  expect(wallSpan(1_000, 10_000, work)).toEqual({ start: 1_000, end: 10_000 });
  expect(wallSpan(1_000, 10_000, undefined)).toEqual({ start: 1_000, end: 10_000 });
});

test("an ended turn's clock runs to its last tool's end, never the first answer", () => {
  const rows = outlastingTurn();
  const [user, ...body] = rows;
  const summary = body.at(-1)!;
  const clock = turnClock(user!, body, undefined, summary);
  expect(clock.durationMs).toBe(2_800);
});

test("Worked for never reads less than the Timeline's total", () => {
  const view = turnView(outlastingTurn(), new Set(), { agentFamily: "claude" });
  const worked = view.find((entry) => entry.kind === WORKED);
  const footer = view.find((entry) => entry.kind === "turnSummary" && entry.turnWork);
  expect(worked).toBeDefined();
  expect(footer).toBeDefined();
  const panel = waterfall(footer!, footer!.turnWork!);
  expect(worked!.durationMs!).toBeGreaterThanOrEqual(panel.total);
  expect(workedLabel(t, worked!)).toStartWith("Worked for 2s");
});

test("a turn under a second reads Worked for 0s", () => {
  const rows: AcpmuxRow[] = [
    row("prompt", 10_000, "user", { text: "Hi" }),
    row("act", 10_010, "activity", { items: [call("one", 10_050, 10_200), call("two", 10_200, 10_400)] }),
    row("answer", 10_500, "assistant", { text: "Done.", assistantPhase: "final_answer" }),
    row("summary", 10_600, "turnSummary", { status: "completed", toolCount: 2, durationMs: 600, turnStartedAtMs: 10_000 }),
  ];
  const view = turnView(rows, new Set(), { agentFamily: "claude" });
  const labels = view.filter((entry) => entry.kind === WORKED).map((entry) => workedLabel(t, entry));
  for (const label of labels) {
    expect(label).toStartWith("Worked for 0s");
    expect(label).not.toContain("<1s");
  }
});

test("a turn with no timed work keeps the harness's own measure", () => {
  const rows: AcpmuxRow[] = [
    row("prompt", 1_000, "user", { text: "Hi" }),
    row("answer", 3_000, "assistant", { text: "Hello.", assistantPhase: "final_answer" }),
    row("summary", 4_000, "turnSummary", { status: "completed", durationMs: 3_000, turnStartedAtMs: 1_000 }),
  ];
  const [user, ...body] = rows;
  expect(turnWork(body)).toBeUndefined();
  expect(turnClock(user!, body, undefined, body.at(-1)).durationMs).toBe(3_000);
});
