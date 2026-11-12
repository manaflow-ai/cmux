// A completed turn keeps its final answer in sight and folds the earlier work, including received
// reports, in place under stable Worked-for disclosures keyed by its prompt (turn-fold-keeps-order.test.ts). A running turn keeps the existing
// step-by-step rows so the reader can follow work as it arrives.
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  openViewTurnFold,
  toggleTurnFold,
  toggleViewTurnFold,
  turnFoldFor,
  SUPERSEDED,
  turnView,
  WORKED,
} from "../src/agent-session/acpmux/conversation/turns";

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
    items: [{ kind: "tool", text: `Ran ${id}`, tool: { id, title: id, kind: "execute", status: "completed" } }],
  });
const answer = (id: string, text: string) => row(id, "assistant", { text });
const received = (id: string) =>
  row(id, "user", {
    text: "The delegated tests passed.",
    // direct.ts preserves user_message.steer and lands it once read; this is the existing
    // relation proving this report belongs inside the active turn rather than a later prompt.
    steer: "landed",
    promptId: `${id}-prompt`,
    incoming: {
      kind: "message",
      message: { name: "test-runner", text: "The delegated tests passed.", raw: "The delegated tests passed." },
    },
  });

/// The ids a view draws, each row a run of messages folds (conversation/messageRuns.ts) included.
const shownIds = (view: readonly AcpmuxRow[]) =>
  view.flatMap((entry) => (entry.messageRun ? [entry.id, ...entry.messageRun.rows] : [entry.id]));

const completedTurn = () => {
  at = 0;
  const prompt = row("prompt", "user", { text: "Ship the retry fix" });
  return [
    prompt,
    tool("read"),
    answer("progress", "I found the retry race and am checking the two call sites."),
    tool("test"),
    received("report"),
    answer("final", "The retry fix is shipped."),
    row("summary", "turnSummary", { status: "completed", durationMs: 7_000 }),
  ];
};

test("a completed turn folds all pre-answer work and received reports under one stable line", () => {
  const rows = completedTurn();
  const folded = turnView(rows, new Set());
  expect(folded.filter((entry) => entry.kind !== "date").map((entry) => `${entry.kind}:${entry.id}`)).toEqual([
    "user:prompt",
    "worked:worked-prompt",
    "assistant:final",
    "turnSummary:summary",
  ]);

  const opened = turnView(rows, new Set([`${WORKED}-prompt`]))
    .filter((entry) => entry.kind !== "date")
    .map((entry) => entry.id);
  // Opened, the work and the report between it fold under one line of messages (messageRuns.ts).
  expect(opened).toEqual(["prompt", "worked-prompt", "messageRun-read", "final", "summary"]);
  const run = turnView(rows, new Set([`${WORKED}-prompt`])).find((entry) => entry.messageRun);
  expect(new Set(run?.messageRun?.rows)).toEqual(new Set(["read", "progress", "test", "report"]));
  expect(
    turnFoldFor(
      rows,
      rows.findIndex((entry) => entry.id === "report"),
    ),
  ).toBe(`${WORKED}-prompt`);
});

test("a running turn keeps intermediate prose, tools, and received reports visible", () => {
  const rows = completedTurn().slice(0, -1);
  const live = turnView(rows, new Set(), { working: true });
  expect(live.some((entry) => entry.kind === WORKED)).toBe(false);
  const ids = shownIds(live);
  for (const id of ["prompt", "read", "progress", "test", "report", "final"]) expect(ids).toContain(id);
});

test("a received prompt without a continuation relation stays a separate turn", () => {
  const rows = completedTurn();
  const unrelated = rows.map((entry) => (entry.id === "report" ? { ...entry, steer: undefined } : entry));
  const folded = turnView(unrelated, new Set());
  // The report opens its own turn, never the prompt's fold: another agent's message that starts a
  // turn folds as that turn's first entry, under its own Worked for (`foldedPrompt`).
  expect(folded.some((entry) => entry.id === `${WORKED}-prompt`)).toBe(false);
  const own = folded.find((entry) => entry.id === `${WORKED}-report`);
  expect(own?.foldedPrompt?.id).toBe("report");
  expect(folded).toContainEqual(expect.objectContaining({ id: "progress" }));
  // Opened, the report draws right under its turn's line.
  const opened = turnView(unrelated, new Set([`${WORKED}-report`])).map((entry) => entry.id);
  expect(opened.indexOf("report")).toBe(opened.indexOf(`${WORKED}-report`) + 1);
});

test("the completed disclosure state is keyed by the turn prompt, so a later snapshot reopens it", () => {
  const rows = completedTurn();
  const expanded = new Set([`${WORKED}-prompt`]);
  const first = turnView(rows, expanded);
  const next = turnView(
    rows.map((entry) => ({ ...entry })),
    expanded,
  );
  expect(first.map((entry) => entry.id)).toEqual(next.map((entry) => entry.id));
  expect(shownIds(next)).toContain("report");
});

test("Find resolves a completed fold when history starts at a landed steer", () => {
  const full = completedTurn();
  const reportAt = full.findIndex((entry) => entry.id === "report");
  const rows = [full[reportAt]!, tool("late-test"), ...full.slice(reportAt + 1)];
  const partialReportAt = rows.findIndex((entry) => entry.id === "report");

  expect(turnFoldFor(rows, partialReportAt)).toBe(`${WORKED}-report`);
  expect(turnView(rows, new Set())).toContainEqual(expect.objectContaining({ id: `${WORKED}-report` }));
});

test("an expanded provisional steer fold stays open when its older prompt arrives", () => {
  const full = completedTurn();
  const reportAt = full.findIndex((entry) => entry.id === "report");
  const partial = [full[reportAt]!, tool("late-test"), ...full.slice(reportAt + 1)];
  const expanded = new Set([`${WORKED}-report`]);

  expect(shownIds(turnView(partial, expanded))).toContain("late-test");

  const loaded = turnView(full, expanded);
  expect(loaded).toContainEqual(expect.objectContaining({ id: `${WORKED}-prompt` }));
  expect(shownIds(loaded)).toContain("report");
});

test("App's toggle call shape (raw snapshot rows) closes a fold a provisional steer key opened", () => {
  // App.tsx passes `snapshot.rows` (turnRowsRef), never the derived turnView rows with their
  // synthetic worked-* rows. The clicked fold must still resolve and clear the provisional key.
  const full = completedTurn();
  const expanded = new Set([`${WORKED}-report`]);
  const isOpen = (keys: ReadonlySet<string>) =>
    turnView(full, keys).find((entry) => entry.id === `${WORKED}-prompt`)?.foldOpen === true;
  expect(isOpen(expanded)).toBe(true);
  expect(full.some((entry) => entry.kind === WORKED)).toBe(false);

  const closed = toggleTurnFold(full, expanded, `${WORKED}-prompt`);
  expect([...closed]).toEqual([]);
  expect(isOpen(closed)).toBe(false);
  expect(turnView(full, closed)).not.toContainEqual(expect.objectContaining({ id: "read" }));

  const reopened = toggleTurnFold(full, closed, `${WORKED}-prompt`);
  expect([...reopened]).toEqual([`${WORKED}-prompt`]);
  expect(isOpen(reopened)).toBe(true);
});

test("a completed fold keeps asks, refusals, and turn context available without opening the work", () => {
  const kinds = [
    "permission",
    "notice",
    "failover",
    "policyUnenforced",
    "agentPair",
    "sessionStart",
    "sessionOffer",
    "startedSessions",
    "workflowCard",
    "questionRecord",
  ];
  for (const kind of kinds) {
    const rows = completedTurn();
    const context = row(`${kind}-context`, kind);
    rows.splice(2, 0, context);
    for (const expanded of [new Set<string>(), new Set([`${WORKED}-prompt`])]) {
      const shown = turnView(rows, expanded);
      expect(shown.filter((entry) => entry.id === context.id)).toHaveLength(1);
      expect(shown.find((entry) => entry.id === context.id)?.settled).not.toBe(true);
      expect(shown.findIndex((entry) => entry.id === context.id)).toBeLessThan(
        shown.findIndex((entry) => entry.id === "final"),
      );
    }
  }
  // A subagent group still running stays in sight as a running call does.
  const rows = completedTurn();
  const running = row("running-agents", "subagents", {
    subagents: [{ id: "x", name: "x", state: "running" } as never],
  });
  rows.splice(2, 0, running);
  for (const expanded of [new Set<string>(), new Set([`${WORKED}-prompt`])])
    expect(turnView(rows, expanded).filter((entry) => entry.id === running.id)).toHaveLength(1);
});

test("agent activity in a completed turn folds with its work, and opens in place", () => {
  // Leo, 2026-11-11, on "Background command completed" and "Subagent finished" rows left between
  // answers: "why aren't these getting folded? ... Do those not count as the works for?"
  const ended = {
    backgroundTask: { backgroundTask: { toolCallId: "c-1", command: "bun test", state: "completed" } },
    subagents: { subagents: [{ id: "x", name: "x", state: "completed" } as never] },
  } as const;
  for (const [kind, extra] of Object.entries(ended)) {
    const rows = completedTurn();
    const work = row(`${kind}-work`, kind, extra as Partial<AcpmuxRow>);
    rows.splice(2, 0, work);
    expect(shownIds(turnView(rows, new Set())).filter((id) => id === work.id)).toHaveLength(0);
    const opened = shownIds(turnView(rows, new Set([`${WORKED}-prompt`])));
    expect(opened.filter((id) => id === work.id)).toHaveLength(1);
    expect(opened.indexOf(work.id)).toBeGreaterThan(opened.indexOf(`${WORKED}-prompt`));
    expect(opened.indexOf(work.id)).toBeLessThan(opened.indexOf("final"));
  }
});

test("render cards keep their call order around the answer and inside their own turn", () => {
  const render = (id: string) =>
    row(id, "activity", {
      items: [
        {
          kind: "tool",
          text: "",
          tool: {
            id,
            title: "mcp__cmux__render",
            status: "completed",
            inputSummary: '{"html":"<p>Report</p>"}',
          },
        },
      ],
    });
  const rows = [
    row("u1", "user"),
    tool("read"),
    render("first"),
    row("context", "notice"),
    render("second"),
    answer("a1", "First result."),
    render("after"),
    row("s1", "turnSummary", { status: "completed" }),
    row("u2", "user"),
    render("third"),
    answer("a2", "Second result."),
    row("s2", "turnSummary", { status: "completed" }),
  ];
  const visible = turnView(rows, new Set()).filter((entry) => !["date", WORKED].includes(entry.kind));
  expect(visible.map((entry) => entry.id)).toEqual([
    "u1",
    "render-first",
    "context",
    "render-second",
    "a1",
    "render-after",
    "s1",
    "u2",
    "render-third",
    "a2",
    "s2",
  ]);
});

test("a pending edit remains available beside the completed fold", () => {
  const pending = row("pending", "activity", {
    items: [{ kind: "tool", text: "", tool: { id: "edit", title: "Edit retry.ts", kind: "edit", status: "pending" } }],
  });
  const rows = completedTurn();
  rows.splice(2, 0, pending);
  for (const expanded of [new Set<string>(), new Set([`${WORKED}-prompt`])]) {
    const shown = turnView(rows, expanded);
    // The step draws as an open fold draws it, closed too: its call keeps a row of its own, the
    // folded-run copy, which takes `:fold` so the edited-files card keeps the step's id.
    const call = shown.find((entry) => entry.id === `${pending.id}:fold`);
    expect(call).toMatchObject({ items: pending.items, foldRun: true });
    expect(call?.ended).not.toBe(true);
    // Its edit is on the turn's edited-files card, once.
    const card = shown.filter((entry) => entry.id === pending.id);
    expect(card).toHaveLength(1);
    expect(card[0]!.merged).toEqual([pending.id]);
  }
});

test("a completed turn of only replies and the person's own steer has no work to fold", () => {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "Write two sentences about the sun" }),
    answer("reply", "The Sun also rises. It warms a cold reach of space."),
    row("steer", "user", { text: "Then say DONE", steer: "landed" }),
    answer("done", "DONE"),
    row("summary", "turnSummary", { status: "completed" }),
  ];
  expect(
    turnView(rows, new Set())
      .filter((entry) => entry.kind !== "date")
      .map((entry) => entry.id),
    // The reply the person came in on ends on its stretch's footer (turns.ts supersededFooters).
  ).toEqual(["prompt", "reply", `${SUPERSEDED}-steer`, "steer", "done", "summary"]);
});

test("Find in Thinking or Verbose opens a turn closed by hand, steer keys included", () => {
  // toggleViewTurnFold marks the prompt's key and each steer's; a reveal must forget them all, or
  // the steer's key keeps the turn closed (cmux#28782 review at 7e02fd5c).
  const full = completedTurn();
  const closed = toggleViewTurnFold(full, new Set(), `${WORKED}-prompt`);
  expect([...closed].sort()).toEqual([`${WORKED}-prompt`, `${WORKED}-report`]);
  expect([...openViewTurnFold(full, closed, `${WORKED}-prompt`)]).toEqual([]);
  expect([...openViewTurnFold(full, closed, `${WORKED}-report`)]).toEqual([]);
  // Nothing closed: the same set back, so the view's state does not change.
  const none = new Set<string>();
  expect(openViewTurnFold(full, none, `${WORKED}-prompt`)).toBe(none);
});
