// A turn's end leaves open the folds over rows the reader has in view (conversation/turnEndHold.ts;
// Leo, 2026-11-03: "sometimes when an agent completes a message while im scrolled up the entire chat
// kinda hitches/shifts a bit?").
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { foldsToHold, oneKeyPerMessageRun, withHeldFolds } from "../src/agent-session/acpmux/conversation/turnEndHold";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

// This file covers the `runs` arm of liveTurnWork.experiment.ts: a running turn keeps its finished
// runs in sight until it ends. The shipped `line` arm (one live line, as chatgpt.com draws a running
// turn) is covered by live-turn-one-line.test.ts.
const liveTurnArmsBefore = globalThis.cmuxExperiments;
beforeAll(() => {
  globalThis.cmuxExperiments = { ...liveTurnArmsBefore, "live-turn-work": "runs" };
});
afterAll(() => {
  globalThis.cmuxExperiments = liveTurnArmsBefore;
});

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
// Shaped on use, after beforeAll picks the `runs` arm.
const runningView = () => turnView(ended.slice(0, -1), new Set(), { working: true });
const hold = (inView: string[], open: ReadonlySet<string> = new Set()) =>
  foldsToHold(ended, turnView(ended, open), runningView(), undefined, inView, open);

test("work in view stays open at the turn's end; the reader's place keeps its rows", () => {
  const folded = turnView(ended, new Set());
  expect(ids(folded)).not.toContain("t1");
  expect(ids(runningView())).toContain("t1");
  // While it ran, every row drew as it came, the short notes between the runs too (cmux#38339): the
  // reader saw the run "t1" and the reply.
  const held = hold(["t1", "answer"]);
  expect(held).toContain("worked-u");
  const open = turnView(ended, withHeldFolds(new Set(), new Set(held)));
  for (const id of ["t1", "answer"]) expect(ids(open)).toContain(id);
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

// cmux#33300: a message run folds under the turn's "Worked for" at its end. A member the reader had
// in view gave the hold its own run key besides the one the run's line toggles, so the run stayed
// open on the first close and needed a second click. A running turn draws no message run
// (cmux#38339): its line forms at the turn's end, over rows the reader has in view.
test("a message run held open at the turn's end closes on one click", () => {
  const tool = (id: string, extra: Record<string, unknown> = {}) => ({
    kind: "tool",
    text: id,
    tool: { id, title: id, kind: "read", status: "completed", ...extra },
  });
  const send = (id: string, to: string) =>
    tool(id, { title: "SendMessage", kind: "other", inputSummary: JSON.stringify({ to, message: "the cap is in" }) });
  const turn = [
    row("p", "user", { text: "Coordinate the lanes" }),
    row("run-1", "activity", { items: [send("s1", "lane-2/coord"), tool("r1"), send("s2", "lane-2/ui")] }),
    row("report", "user", {
      text: "",
      continues: true,
      incoming: { kind: "message", message: { name: "verify", sessionId: "verify", text: "Merged", raw: "Merged" } },
    }),
    row("run-2", "activity", { items: [tool("r2"), send("s3", "lane-2/owner"), tool("r3")] }),
    row("p-answer", "assistant", { text: "Every lane has its orders. ".repeat(6) + "\n\n- one\n- two" }),
  ];
  const done = [...turn, row("p-end", "turnSummary", { status: "completed", durationMs: 9_000 })];
  const codex = { agentFamily: "codex" } as const;
  // While the turn ran, its rows drew as they came, with no message run's line over them.
  const open = new Set<string>();
  const live = turnView(turn, open, { ...codex, working: true });
  expect(live.some((each) => each.kind === "messageRun")).toBe(false);
  for (const id of ["run-1", "report", "run-2"]) expect(ids(live)).toContain(id);
  // The turn ends with two members of the run in view: the hold keeps the turn's fold open, and the
  // run open by the one key its line toggles (App.tsx shapes the view with the held folds first).
  const each = foldsToHold(done, turnView(done, open, codex), live, undefined, ["report", "run-2"], open);
  const held = oneKeyPerMessageRun(each, turnView(done, new Set([...open, ...each]), codex));
  expect(held).toContain("worked-p");
  expect(held.filter((key) => key.startsWith("messageRun-"))).toHaveLength(1);
  const expanded = new Set([...open, ...held]);
  const kept = turnView(done, expanded, codex);
  const keptLine = kept.find((each) => each.kind === "messageRun")!;
  expect(keptLine.foldOpen).toBe(true);
  expect(ids(kept)).toContain("run-2");
  // One click on the run's line closes it.
  expanded.delete(keptLine.id);
  const closed = turnView(done, expanded, codex);
  expect(closed.find((each) => each.kind === "messageRun")?.foldOpen).toBe(false);
  expect(ids(closed)).not.toContain("run-2");
});
