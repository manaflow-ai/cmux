// A turn's end leaves open the folds over rows the reader has in view (conversation/turnEndHold.ts;
// Leo, 2026-11-03: "sometimes when an agent completes a message while im scrolled up the entire chat
// kinda hitches/shifts a bit?").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { foldsToHold, withHeldFolds } from "../src/agent-session/acpmux/conversation/turnEndHold";
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
const note = (id: string) => row(id, "assistant", { text: `Checking ${id}: it retries on every error.` });
const reply = row("answer", "assistant", {
  text: "Every retry loop now shares one capped backoff. ".repeat(4) + "\n\n- one\n- two",
});
const ended = [
  row("old", "user", { text: "Earlier" }),
  row("old-reply", "assistant", { text: "Earlier reply" }),
  row("old-end", "turnSummary", { status: "completed", durationMs: 1_000 }),
  row("u", "user", { text: "Fix the cap" }),
  note("n1"),
  tool("t1"),
  note("n2"),
  tool("t2"),
  reply,
  row("end", "turnSummary", { status: "completed", durationMs: 9_000 }),
];
const ids = (rows: AcpmuxRow[]) => rows.filter((each) => each.kind !== "date").map((each) => each.id);

// The view while the turn ran: every row drawn.
const running = turnView(ended.slice(0, -1), new Set(), { working: true });
const hold = (inView: string[], open: ReadonlySet<string> = new Set()) =>
  foldsToHold(ended, turnView(ended, open), running, undefined, inView, open);

test("work in view stays open at the turn's end; the reader's place keeps its rows", () => {
  const folded = turnView(ended, new Set());
  expect(ids(folded)).not.toContain("t1");
  expect(ids(running)).toContain("t1");
  const held = hold(["n2", "t2", "answer"]);
  expect(held).toContain("worked-u");
  const open = turnView(ended, withHeldFolds(new Set(), new Set(held)));
  for (const id of ["n2", "t2", "answer"]) expect(ids(open)).toContain(id);
});

test("a reader in older turns, or only on the prompt and the reply, holds nothing open", () => {
  expect(hold(["old", "old-reply"])).toEqual([]);
  expect(hold(["u", "answer"])).toEqual([]);
  // The live line the running turn drew is not a row of the chat: it needs no fold.
  expect(hold(["working-u", "thinking-live"])).toEqual([]);
});

test("a fold the reader already opened is not held again", () => {
  expect(hold(["t1"], new Set(["worked-u"]))).toEqual([]);
});

test("rows in the unchanged prefix are not looked at", () => {
  // Nothing after the prefix went: a reader in history holds nothing, however long the chat.
  const view = turnView(ended, new Set());
  expect(foldsToHold(ended, view, view, view.length, ["t1"], new Set())).toEqual([]);
});
