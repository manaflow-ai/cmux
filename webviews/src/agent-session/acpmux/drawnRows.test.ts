import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { WORKED } from "./conversation/turns";
import { changeHidden, drewRunningTurn, hiddenUnderFold } from "./drawnRows";
import { sameButRows } from "./liveToolOutput";
import { markOneRowChange } from "./rowChanges";

const user: AcpmuxRow = { id: "u1", version: 1, at: 1, kind: "user" };
const call = (id: string, status: string): AcpmuxRow => ({
  id,
  version: status === "completed" ? 2 : 1,
  at: 2,
  kind: "activity",
  items: [{ kind: "tool", tool: { id, title: `Read ${id}`, kind: "read", status } } as unknown as AcpmuxActivity],
});
const header = (foldOpen: boolean): AcpmuxRow => ({
  id: "worked-u1",
  version: 1,
  at: 1,
  kind: WORKED,
  turnPhase: "running",
  foldOpen,
});
const line: AcpmuxRow = { id: "thinking-live", version: 1, at: 3, kind: "thinking" } as AcpmuxRow;

test("a row of the running turn the closed fold leaves undrawn is hidden", () => {
  drewRunningTurn([user, header(false), line]);
  const rows = [user, call("c1", "in_progress")];
  expect(hiddenUnderFold(rows, 1)).toBe(true);
  const previous = { rows } as AcpmuxSnapshot;
  const next = { rows: [user, call("c1", "completed")] } as AcpmuxSnapshot;
  markOneRowChange(next.rows, previous.rows, 1);
  expect(changeHidden(previous, next)).toBe(true);
});

test("the open fold, a drawn row, or a row before a later prompt is not hidden", () => {
  const rows = [user, call("c1", "in_progress")];
  drewRunningTurn([user, header(true), line]);
  expect(hiddenUnderFold(rows, 1)).toBe(false);
  // A call waiting on its permission keeps its own row under the closed fold: drawn, so not hidden.
  drewRunningTurn([user, header(false), call("c1", "pending"), line]);
  expect(hiddenUnderFold(rows, 1)).toBe(false);
  drewRunningTurn([{ ...user, id: "u2" }, header(false), line]);
  expect(hiddenUnderFold([...rows, { ...user, id: "u2" }], 1)).toBe(false);
});

test("two streamed record kinds in connection read as the same snapshot; a link change does not", () => {
  const rows: AcpmuxRow[] = [];
  const at = (connection: string) => ({ rows, connection }) as unknown as AcpmuxSnapshot;
  expect(sameButRows(at("tool_call"), at("tool_call_update"))).toBe(true);
  expect(sameButRows(at("tool_call_update"), at("agent_thought_chunk"))).toBe(true);
  expect(sameButRows(at("tool_call"), at("disconnected"))).toBe(false);
  expect(sameButRows(at("attached"), at("tool_call"))).toBe(false);
});
