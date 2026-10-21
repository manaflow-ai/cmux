// A finished turn's todo list stops spinning (PlanList's `ended`): every way a turn ends marks
// its plan row `turnEnded`, and only a running turn's plan stays live.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const plan = (id: string) => row(id, "plan", { plan: [{ content: "Run the tests", status: "in_progress" }] });
const summary = (id: string) => row(id, "turnSummary", { status: "completed" });

const planRow = (rows: AcpmuxRow[], id: string, working = false) =>
  turnView(rows, new Set(), { working }).find((shaped) => shaped.id === id);

test("a running turn's plan stays live", () => {
  expect(planRow([row("u", "user"), plan("p")], "p", true)?.turnEnded).toBeUndefined();
});

test("the last turn without a summary, no longer working, ends its plan", () => {
  expect(planRow([row("u", "user"), plan("p")], "p")?.turnEnded).toBe(true);
});

test("an earlier turn without a summary or other work ends its plan", () => {
  const rows = [row("u1", "user"), plan("p"), row("u2", "user"), row("a2", "assistant", { text: "ok" })];
  expect(planRow(rows, "p")?.turnEnded).toBe(true);
});

test("a plan sent after the answer ends with the turn", () => {
  const rows = [row("u", "user"), row("a", "assistant", { text: "done" }), plan("p"), summary("s")];
  expect(planRow(rows, "p")?.turnEnded).toBe(true);
});

test("a plan arriving after the summary ends with the turn", () => {
  const rows = [row("u", "user"), row("a", "assistant", { text: "done" }), summary("s"), plan("p")];
  expect(planRow(rows, "p")?.turnEnded).toBe(true);
});

test("an earlier turn without a summary ends a plan sent after its answer", () => {
  const rows = [
    row("u1", "user"),
    row("t1", "thought", { text: "Reading the branch" }),
    row("a1", "assistant", { text: "done" }),
    plan("p"),
    row("u2", "user"),
    row("a2", "assistant", { text: "ok" }),
  ];
  expect(planRow(rows, "p")?.turnEnded).toBe(true);
});

test("a turn the agent started on its own after the summary keeps its plan live", () => {
  const rows = [row("u", "user"), row("a", "assistant", { text: "done" }), summary("s"), plan("p")];
  expect(planRow(rows, "p", true)?.turnEnded).toBeUndefined();
});
