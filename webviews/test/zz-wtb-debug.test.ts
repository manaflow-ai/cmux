// Temporary debug probe (wrc-transcript-b); removed before commit.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 3, 20, 0, 0);
let at = START;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({ id, kind, version: 1, at: (at += 10_000), ...extra });
const bash = (id: string) =>
  row(`a-${id}`, "activity", { items: [{ kind: "tool", text: "", tool: { id, title: `Run ${id}`, kind: "execute", status: "completed" } }] });
const steeredThenEnded = (after: AcpmuxRow[] = []) => [
  row("u", "user", { text: "Plan the transfer work" }),
  row("r1", "assistant", { text: "Got it. I've dropped the plan." }),
  row("s1", "user", { text: "THIS IS THE THING", steer: "landed" }),
  ...after,
  row("sum", "turnSummary", { status: "completed", durationMs: 30_000 }),
];
const dump = (name: string, rows: AcpmuxRow[]) => {
  const view = turnView(rows, new Set(), { agentFamily: "claude", now: START + 1e6 });
  console.log("WTBDEBUG " + name + " IN " + JSON.stringify(rows.map((r) => [r.id, r.kind, r.at - START])));
  console.log("WTBDEBUG " + name + " OUT " + JSON.stringify(view.map((r) => [r.id, r.kind, r.text?.slice(0, 20), r.turnCopy, r.items?.map((i) => i.tool?.id)])));
};
test("probe", () => {
  dump("one", steeredThenEnded());
  dump("two", steeredThenEnded([row("s2", "user", { text: "AND THIS", steer: "landed" })]));
  const u = row("u", "user", { text: "Plan" }), r1 = row("r1", "assistant", { text: "Got it." }), s1 = row("s1", "user", { text: "THIS", steer: "landed" });
  const s2 = row("s2", "user", { text: "AND THIS", steer: "landed" }), b9 = bash("b9"), sum = row("sum", "turnSummary", { status: "completed", durationMs: 30_000 });
  dump("ordered2", [u, r1, s1, s2, sum]);
  dump("orderedb9", [u, r1, s1, b9, sum]);
  dump("b9", steeredThenEnded([bash("b9")]));
  expect("probe-output-retained").toBe("");
});
