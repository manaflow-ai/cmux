// A turn's end leaves open the folds over rows the reader has in view (conversation/turnEndHold.ts;
// Leo, 2026-11-03: "sometimes when an agent completes a message while im scrolled up the entire chat
// kinda hitches/shifts a bit?"), except the turn's own Worked for, which always closes (Lucas,
// 2026-11-11).
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { foldsToHold, withHeldFolds } from "../src/agent-session/acpmux/conversation/turnEndHold";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

// This file covers the `runs` arm of liveTurnWork.experiment.ts: a running turn keeps each finished
// run in sight as its folded summary line. The `line` arm (one live line, as chatgpt.com draws a running
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

test("the turn's Worked for closes at its end, even over work in view (Lucas, 2026-11-11)", () => {
  const folded = turnView(ended, new Set());
  expect(ids(folded)).not.toContain("t1");
  expect(ids(runningView())).toContain("t1");
  // The reader saw the run "t1" and the reply while the turn ran; at its end the Worked for still
  // closes ("the Worked for should ALWAYS collapse when the turn has ended"), the reply in sight.
  const held = hold(["t1", "answer"]);
  expect(held).not.toContain("worked-u");
  const shown = turnView(ended, withHeldFolds(new Set(), new Set(held)));
  expect(ids(shown)).not.toContain("t1");
  expect(ids(shown)).toContain("answer");
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

// cmux#33300: a message run open while the turn ran folds under the turn's "Worked for" at its end.
// A member the reader had in view gave the hold its own run key besides the one the run's line
// toggles, so the run stayed open on the first close and needed a second click. The Worked for itself
// closes at the end (2026-11-11); the run keeps one key, so once the reader opens the Worked for
// again, one click closes the run.
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
  // While the turn ran, the reader opened its run of messages.
  const closedLive = turnView(turn, new Set(), { ...codex, working: true });
  const line = closedLive.find((each) => each.kind === "messageRun")!;
  expect(line.messageRun?.rows).toEqual(expect.arrayContaining(["run-1", "report", "run-2"]));
  const open = new Set([line.id]);
  const live = turnView(turn, open, { ...codex, working: true });
  expect(ids(live)).toContain("run-2");
  // The turn ends with a later member of the run in view: the Worked for closes all the same.
  const held = foldsToHold(done, turnView(done, open, codex), live, undefined, ["report", "run-2"], open);
  expect(held).not.toContain("worked-p");
  // The reader opens the Worked for again: the run is open by its one key, and one click closes it.
  const expanded = new Set([...open, ...held, "worked-p"]);
  const kept = turnView(done, expanded, codex);
  const keptLine = kept.find((each) => each.kind === "messageRun")!;
  expect(keptLine.foldOpen).toBe(true);
  expect(ids(kept)).toContain("run-2");
  expanded.delete(keptLine.id);
  const closed = turnView(done, expanded, codex);
  expect(closed.find((each) => each.kind === "messageRun")?.foldOpen).toBe(false);
  expect(ids(closed)).not.toContain("run-2");
});

test("the last turn's Worked for keys are its opener's and each steer's, never an earlier turn's", async () => {
  const { lastTurnWorkedKeys } = await import("../src/agent-session/acpmux/conversation/turnEndHold");
  const steer = row("s", "user", { text: "Also the cap", continues: true } as Partial<AcpmuxRow>);
  expect(lastTurnWorkedKeys([...ended, steer, row("s-end", "turnSummary", { status: "completed" })])).toEqual([
    "worked-s",
    "worked-u",
  ]);
  expect(lastTurnWorkedKeys([])).toEqual([]);
  // A steer that failed to send opens no turn of its own here: the walk goes past it to the prompt.
  const failed = row("f", "user", { text: "Also the cap", failed: true } as Partial<AcpmuxRow>);
  expect(lastTurnWorkedKeys([...ended, failed]).at(-1)).toBe("worked-u");
});
