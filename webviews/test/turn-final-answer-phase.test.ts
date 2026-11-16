// l10n-allow-file: test fixture replies and commands, not shipped UI.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { LIVE_THINKING, WORKED, toggleTurnFold, turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { viewFolds } from "../src/agent-session/acpmux/conversation/viewFolds";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  at: 1_000,
  version: 1,
  ...extra,
});
const prompt = row("prompt", "user", { text: "Check the code" });
const commentary = row("commentary", "assistant", { text: "Checking the caller.", assistantPhase: "commentary" });
const call = row("call", "activity", {
  items: [
    {
      kind: "tool",
      text: "Read caller.ts",
      tool: { id: "read", title: "Read caller.ts", kind: "read", status: "completed" },
    },
  ],
});
const answer = row("answer", "assistant", {
  at: 5_000,
  text: "The fix is ready.",
  assistantPhase: "final_answer",
  streaming: true,
});
const summary = row("summary", "turnSummary", { at: 7_000, status: "completed", durationMs: 6_000 });
const work = [prompt, commentary, call];
const options = { agentFamily: "codex", working: true, now: 10_000 };
const foldId = "worked-prompt";
const shownIds = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind !== "date").map((row) => row.id);

test("explicit final answer folds prior work while the turn still runs, then keeps the same fold at completion", () => {
  const before = turnViewFrom(work, new Set(), options);
  expect(before.rows.some((row) => row.kind === WORKED)).toBe(false);
  const final = turnViewFrom([...work, answer], new Set(), options, before);
  expect(shownIds(final.rows)).toEqual(["prompt", foldId, "answer", LIVE_THINKING]);
  expect(final.rows.find((row) => row.kind === WORKED)).toMatchObject({ id: foldId, foldOpen: false });
  expect(final.rows.some((row) => row.kind === "turnSummary")).toBe(false);
  const done = turnViewFrom([...work, { ...answer, streaming: false }, summary], new Set(), {
    ...options,
    working: false,
  });
  expect(shownIds(done.rows)).toEqual(["prompt", foldId, "answer", "summary"]);
  expect(done.rows.findIndex((row) => row.id === foldId)).toBe(final.rows.findIndex((row) => row.id === foldId));
  expect(done.rows.find((row) => row.id === "summary")?.turnCopy).toBeDefined();
});

test("manual expansion survives final answer chunks and completion without losing work", () => {
  const source = [...work, answer];
  const expanded = toggleTurnFold(source, new Set(), foldId);
  const first = turnViewFrom(source, expanded, options);
  const nextAnswer = { ...answer, version: 2, text: `${answer.text} Tests pass.` };
  const next = turnViewFrom([...work, nextAnswer], expanded, options, first);
  const done = turnViewFrom([...work, nextAnswer, summary], expanded, { ...options, working: false }, next);
  for (const view of [first, next, done]) {
    expect(view.rows.find((row) => row.id === foldId)?.foldOpen).toBe(true);
    expect(view.rows.some((row) => row.id === commentary.id)).toBe(true);
    expect(view.rows.flatMap((row) => row.items ?? []).some((item) => item.tool?.id === "read")).toBe(true);
    expect(view.rows.filter((row) => row.id === answer.id)).toHaveLength(1);
  }
  expect(next.rows.find((row) => row.id === answer.id)?.text).toBe(nextAnswer.text);
});

test("commentary is never selected as the final answer and every explicit final remains outside", () => {
  const anotherFinal = { ...answer, id: "second-answer", text: "One more result." };
  const tailComment = { ...commentary, id: "tail-commentary", text: "Checking the follow-up." };
  const done = turnViewFrom([...work, answer, anotherFinal, tailComment, summary], new Set(), {
    ...options,
    working: false,
  });
  expect(shownIds(done.rows)).toEqual(["prompt", foldId, "answer", "second-answer", "summary"]);
  expect(done.rows.find((row) => row.id === "summary")?.text).toBe(anotherFinal.text);
  const noFinal = turnViewFrom([...work, summary], new Set(), { ...options, working: false });
  expect(noFinal.rows.some((row) => row.id === commentary.id)).toBe(false);
  expect(noFinal.rows.find((row) => row.id === "summary")?.text).toBeUndefined();
});

test("an empty final phase waits for visible content and unphased turns retain their live behavior", () => {
  for (const latest of [
    { ...answer, text: "" },
    { ...answer, assistantPhase: undefined },
  ]) {
    const live = turnViewFrom([...work, latest], new Set(), options);
    expect(live.rows.some((row) => row.kind === WORKED)).toBe(false);
  }
});

for (const status of ["cancelled", "interrupted"])
  test(`${status} turns retain their work until explicitly folded, including after a final started`, () => {
    const source = [...work, answer, { ...summary, status }];
    const open = turnViewFrom(source, new Set(), { ...options, working: false });
    expect(open.rows.find((row) => row.id === foldId)?.foldOpen).toBe(true);
    const closedChoice = toggleTurnFold(source, new Set(), foldId);
    const closed = turnViewFrom(source, closedChoice, { ...options, working: false }, open);
    expect(closed.rows.find((row) => row.id === foldId)?.foldOpen).toBe(false);
    expect(closed.rows.some((row) => row.id === commentary.id)).toBe(false);
    const openedChoice = toggleTurnFold(source, closedChoice, foldId);
    expect(
      turnViewFrom(source, openedChoice, { ...options, working: false }).rows.find((row) => row.id === foldId)
        ?.foldOpen,
    ).toBe(true);
    const thinkingClosed = viewFolds("thinking", new Set(), new Set([foldId]));
    expect(
      turnViewFrom(source, thinkingClosed, { ...options, working: false }).rows.find((row) => row.id === foldId)
        ?.foldOpen,
    ).toBe(false);
  });

test("a manual close during the final answer stays closed if that turn is cancelled", () => {
  const live = [...work, answer];
  const expanded = toggleTurnFold(live, new Set(), foldId);
  const closed = toggleTurnFold(live, expanded, foldId);
  const cancelled = turnViewFrom([...live, { ...summary, status: "cancelled" }], closed, {
    ...options,
    working: false,
  });
  expect(cancelled.rows.find((row) => row.id === foldId)?.foldOpen).toBe(false);
});

test("Worked for freezes at the first final answer while the footer keeps the full turn duration", () => {
  const final = { ...answer, at: prompt.at + 15_000 };
  const live = turnViewFrom([...work, final], new Set(), options);
  const completed = { ...summary, at: prompt.at + 35_000, durationMs: 35_000 };
  const done = turnViewFrom(
    [...work, { ...final, version: 2, text: `${final.text} Tests pass.` }, completed],
    new Set(),
    {
      ...options,
      working: false,
    },
  );
  expect(live.rows.find((row) => row.kind === WORKED)?.durationMs).toBe(15_000);
  expect(done.rows.find((row) => row.kind === WORKED)?.durationMs).toBe(15_000);
  expect(done.rows.find((row) => row.kind === "turnSummary")?.durationMs).toBe(35_000);
  const resumed = turnViewFrom([...work, final, { ...completed, turnStartedAtMs: prompt.at + 5_000 }], new Set(), {
    ...options,
    working: false,
    turnStartedAtMs: 90_000,
  });
  expect(resumed.rows.find((row) => row.kind === WORKED)?.durationMs).toBe(10_000);
});

for (const status of ["cancelled", "interrupted"])
  test(`${status} phased work around a personal steer closes each segment independently`, () => {
    const steer = row("steer", "user", { at: 2_000, text: "Check the second caller too.", steer: "landed" });
    const secondCall = {
      ...call,
      id: "second-call",
      at: 3_000,
      items: [{ ...call.items![0]!, tool: { ...call.items![0]!.tool!, id: "read-second" } }],
    };
    const source = [...work, steer, secondCall, answer, { ...summary, status }];
    const settled = { ...options, working: false };
    const first = turnViewFrom(source, new Set(), settled);
    const folds = first.rows.filter((row) => row.kind === WORKED);
    expect(folds.map((row) => row.id)).toEqual([foldId, "worked-steer"]);
    expect(folds.map((row) => row.foldOpen)).toEqual([true, true]);
    expect(folds.map((row) => row.durationMs)).toEqual([1_000, 3_000]);
    const choice = toggleTurnFold(source, new Set(), foldId);
    const closed = turnViewFrom(source, choice, settled, first);
    expect(closed.rows.find((row) => row.id === foldId)?.foldOpen).toBe(false);
    expect(closed.rows.find((row) => row.id === "worked-steer")?.foldOpen).toBe(true);
    expect(closed.rows.some((row) => row.id === call.id)).toBe(false);
    expect(closed.rows.some((row) => row.id === secondCall.id)).toBe(true);
    expect(closed.rows.filter((row) => row.id === answer.id)).toHaveLength(1);
    const reopened = turnViewFrom(source, toggleTurnFold(source, choice, foldId), settled, closed);
    expect(reopened.rows.find((row) => row.id === foldId)?.foldOpen).toBe(true);
    expect(reopened.rows.some((row) => row.id === call.id)).toBe(true);
    expect(reopened.rows.indexOf(reopened.rows.find((row) => row.id === "steer")!)).toBeLessThan(
      reopened.rows.indexOf(reopened.rows.find((row) => row.id === secondCall.id)!),
    );
  });

for (const status of ["cancelled", "interrupted"])
  test(`${status} work after a continued summary closes on the first click`, () => {
    const continued = { ...summary, id: "continued", at: 2_000, status: "interrupted", continued: true };
    const steer = row("continuing-steer", "user", { at: 3_000, text: "Finish the check.", steer: "landed" });
    const source = [
      ...work,
      continued,
      steer,
      { ...call, id: "after-steer", at: 4_000 },
      answer,
      { ...summary, status },
    ];
    const settled = { ...options, working: false };
    const before = turnViewFrom(source, new Set(), settled);
    expect(before.rows.find((row) => row.id === foldId)?.foldOpen).toBe(true);
    const choice = toggleTurnFold(source, new Set(), foldId);
    const closed = turnViewFrom(source, choice, settled, before);
    expect(closed.rows.find((row) => row.id === foldId)?.foldOpen).toBe(false);
    expect(closed.rows.some((row) => row.id === call.id)).toBe(false);
  });

test("substantive commentary before a tool survives explicit final receipt, completion and reload", () => {
  const finding = {
    ...commentary,
    id: "finding",
    text: "Small is slower because startup dominates.\n\n| lane | time |\n| --- | --- |\n| small | 14s |\n| huge | 3s |\n\nThe larger lane amortizes setup.",
  };
  // Even narration-shaped text is an answer when the provider explicitly marks it final.
  const receipt = { ...answer, text: "Checking the follow-up." };
  const source = [prompt, commentary, finding, call, receipt];
  const live = turnViewFrom(source, new Set(), options);
  const completed = [prompt, commentary, finding, call, { ...receipt, streaming: false }, summary];
  const done = turnViewFrom(completed, new Set(), { ...options, working: false }, live);
  const reloaded = turnViewFrom(completed, new Set(), { ...options, working: false });
  for (const view of [live, done, reloaded]) {
    expect(view.rows.filter((row) => row.id === finding.id)).toHaveLength(1);
    expect(view.rows.filter((row) => row.id === receipt.id)).toHaveLength(1);
    expect(view.rows.some((row) => row.id === commentary.id)).toBe(false);
    expect(view.rows.some((row) => row.id === call.id)).toBe(false);
  }
});
