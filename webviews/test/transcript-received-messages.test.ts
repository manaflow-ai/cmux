// Leo, 2026-10-20: when a new message arrives, the agent's earlier messages must not fold into
// "N previous messages". Another agent's message that arrives while a turn runs is a prompt, so it
// starts a turn of its own and the turn before it has no summary yet. That turn draws as it came:
// each of the agent's messages stays on its own line, in place, and only the person folds anything.
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
const tool = (id: string) =>
  row(id, "activity", {
    items: [{ kind: "tool", text: "", tool: { id, title: id, kind: "read", status: "completed" } }],
  });
const text = (id: string) => row(id, "assistant", { text: id });
const received = (id: string) =>
  row(id, "user", {
    text: "The grid fix is on cmux/grid-fix.",
    incoming: { kind: "message", message: { name: "Grid fix", text: "The grid fix is on cmux/grid-fix.", raw: "" } },
  });
const drawn = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set())
    .filter((shaped) => shaped.kind !== "date")
    .map((shaped) => `${shaped.kind}:${shaped.id}`);

test("a message that arrives mid-turn leaves the agent's earlier messages in place", () => {
  const rows = [
    row("u1", "user"),
    text("first"),
    tool("read"),
    text("second"),
    tool("grep"),
    received("m1"),
    text("third"),
    received("m2"),
    text("fourth"),
  ];
  expect(drawn(rows)).toEqual([
    "user:u1",
    "assistant:first",
    "activity:read",
    "assistant:second",
    "activity:grep",
    "user:m1",
    "assistant:third",
    "user:m2",
    "assistant:fourth",
  ]);
});

test("no turn without a summary folds into previous messages", () => {
  const rows = [row("u1", "user"), text("interim"), tool("read"), row("u2", "user"), text("answer")];
  const shaped = turnView(rows, new Set());
  expect(shaped.some((entry) => entry.previous !== undefined)).toBe(false);
  expect(shaped.map((entry) => entry.id)).toContain("interim");
});
