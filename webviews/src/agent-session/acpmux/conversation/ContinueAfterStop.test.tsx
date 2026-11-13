// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Stopped-turn eligibility belongs to the empty composer's Resume control. The footer has no
// Continue control; failed-turn recovery keeps its existing text fallback.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import { layoutConversation, type AcpmuxRow } from "../model";
import { CONTINUE_PROMPT, resumeThrough, RetryTargetContext, TurnActionsContext } from "./turnActions";
import { TurnFooter } from "./TurnRows";
import { PromptActions } from "./MessageActions";
import { isEmptyFooter, turnView } from "./turns";

const prompt = (id: string, at: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "user",
  text: "Add retries to the fetch helper",
  ...fields,
});
const answer = (id: string, at: number): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text: "Done." });
const summary = (id: string, at: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "turnSummary",
  durationMs: 40_000,
  status: "completed",
  ...fields,
});

const footers = (rows: AcpmuxRow[], working = false) =>
  turnView(rows, new Set(), { now: 100_000, working }).filter((row) => row.kind === "turnSummary");

const stoppedTurn = [prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 41_000, { status: "cancelled" })];

test("a stopped last turn exposes Resume eligibility", () => {
  expect(footers(stoppedTurn).map((row) => row.resumable)).toEqual([true]);
  // An interruption reads as a stop too.
  const interrupted = [prompt("p1", 1_000), summary("s1", 41_000, { status: "interrupted" })];
  expect(footers(interrupted).map((row) => row.resumable)).toEqual([true]);
});

test("completed and failed turns expose no stopped-turn Resume", () => {
  for (const status of ["completed", "failed", "error"]) {
    const rows = [prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 41_000, { status })];
    expect(footers(rows)[0]!.resumable).toBeUndefined();
  }
});

test("only the latest stopped turn exposes Resume eligibility", () => {
  const rows = [
    ...stoppedTurn,
    prompt("p2", 50_000),
    answer("a2", 60_000),
    summary("s2", 61_000, { status: "cancelled" }),
  ];
  expect(footers(rows).map((row) => row.resumable)).toEqual([undefined, true]);
  const completedLast = [...stoppedTurn, prompt("p2", 50_000), answer("a2", 60_000), summary("s2", 61_000)];
  expect(footers(completedLast).map((row) => row.resumable)).toEqual([undefined, undefined]);
});

test("a stopped turn loses Resume eligibility after the agent finishes its successor", () => {
  const rows = [...stoppedTurn, answer("a2", 50_000), summary("s2", 51_000, { status: "completed" })];
  expect(footers(rows).every((row) => !row.resumable)).toBe(true);
});

test("an agent-started stopped turn records Resume eligibility on its own summary", () => {
  for (const status of ["cancelled", "interrupted"]) {
    const rows = [
      prompt("p1", 1_000),
      answer("a1", 30_000),
      summary("s1", 41_000),
      answer("a2", 50_000),
      summary("s2", 51_000, { status }),
    ];
    const [first, second] = footers(rows);
    expect(first!.resumable).toBeUndefined();
    expect(second!.resumable).toBe(true);
    // Its version moves, so readers of resumable eligibility update.
    expect(second!.version).not.toBe(1);
    // A prompt sent after it removes that eligibility again.
    const sent = footers([...rows, prompt("p2", 60_000, { pending: true })]);
    expect(sent.every((row) => !row.resumable)).toBe(true);
  }
});

// Review at c3ec4170 (P2): with daemon turn ids, the agent's own turn in the tail names a turn other
// than the prompt's; its Stop still exposes Resume eligibility.
test("an agent-started stopped turn retains Resume eligibility with its own turn id", () => {
  const rows = [
    prompt("p1", 1_000, { turnId: "turn-a" }),
    answer("a1", 30_000),
    summary("s1", 41_000, { turnId: "turn-a" }),
    answer("a2", 50_000),
    summary("s2", 51_000, { status: "cancelled", turnId: "turn-b" }),
  ];
  const [first, second] = footers(rows);
  expect(first!.resumable).toBeUndefined();
  expect(second!.resumable).toBe(true);
});

test("a continued result does not expose stopped-turn Resume", () => {
  const rows = [prompt("p1", 1_000), summary("s1", 41_000, { status: "cancelled", continued: true })];
  expect(footers(rows).every((row) => !row.resumable)).toBe(true);
});

test("Resume eligibility clears when another prompt starts or the turn runs again", () => {
  // The continue prompt is sent and not yet taken: it waits under the stopped turn.
  const sending = [...stoppedTurn, prompt("p2", 50_000, { text: CONTINUE_PROMPT, pending: true })];
  expect(footers(sending)[0]!.resumable).toBeUndefined();
  // Taken: a new turn has started, still running.
  const started = [...stoppedTurn, prompt("p2", 50_000, { text: CONTINUE_PROMPT })];
  expect(footers(started, true)[0]!.resumable).toBeUndefined();
  // The stopped turn itself running again (the agent went on after its summary).
  expect(footers(stoppedTurn, true)[0]!.resumable).toBeUndefined();
});

test("the summary version changes when Resume eligibility comes or goes", () => {
  const offered = footers(stoppedTurn)[0]!;
  const gone = footers([...stoppedTurn, prompt("p2", 50_000, { pending: true })])[0]!;
  expect(offered.version).not.toBe(gone.version);
});

test("a stopped footer has no Continue even when resume is available", () => {
  const row = footers(stoppedTurn)[0]!;
  const withResume = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ resume: async () => undefined }}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );
  // In whatever language the table is in (another test file may have switched it).
  expect(withResume).not.toContain("cv-turn-continue");
  expect(withResume).not.toContain("cv-turn-actions--resumable");
  // By default the footer says nothing of the stop: no muted Stopped and no time with its tooltip
  // (Lawrence and Lucas, 2026-11-11 standup: Codex shows no "Stopped" and no time on hover).
  expect(withResume).not.toContain("cv-turn-stopped");
  expect(withResume).not.toContain(translate("turn.stopped", { time: "40s" }));
  // The "word" arm still draws Stopped, with how long it ran in its tooltip.
  const originalExperiments = Object.getOwnPropertyDescriptor(globalThis, "cmuxExperiments");
  globalThis.cmuxExperiments = { "stopped-turn-look": "word" };
  try {
    const word = renderToStaticMarkup(
      <TurnActionsContext.Provider value={{ resume: async () => undefined }}>
        <TurnFooter row={row} />
      </TurnActionsContext.Provider>,
    );
    expect(word).toContain("cv-turn-stopped");
    expect(word).toContain(translate("turn.stopped", { time: "40s" }));
  } finally {
    if (originalExperiments) Object.defineProperty(globalThis, "cmuxExperiments", originalExperiments);
    else delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
  }
  // No action (a View Only chat, or not connected): no button.
  expect(renderToStaticMarkup(<TurnFooter row={row} />)).not.toContain("cv-turn-continue");
  // There a folded stopped turn with nothing else to show (no answer and nothing it said to copy)
  // keeps no line for it. One that said something keeps its Copy row (turns.ts endsChatOnWork).
  const folded = { ...row, folded: true, text: undefined, turnCopy: undefined };
  expect(renderToStaticMarkup(<TurnFooter row={folded} />)).toContain("cv-turn-actions--empty");
  // A completed turn's footer never draws it, even with the action.
  const done = footers([prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 41_000)])[0]!;
  expect(
    renderToStaticMarkup(
      <TurnActionsContext.Provider value={{ resume: async () => undefined }}>
        <TurnFooter row={done} />
      </TurnActionsContext.Provider>,
    ),
  ).not.toContain("cv-turn-continue");
});

test("failed recovery sends the existing continue-text fallback through chat.send", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const resume = resumeThrough(async (method, params) => {
    calls.push([method, params]);
  });
  await resume();
  expect(calls).toEqual([["chat.send", { text: CONTINUE_PROMPT }]]);
});

test("a refused continue send is swallowed; its row says why", async () => {
  const resume = resumeThrough(() => Promise.reject(new Error("refused")));
  await expect(resume()).resolves.toBeUndefined();
});

test("a folded stopped turn keeps Resume metadata without a footer band", () => {
  const rows = [
    prompt("p1", 1_000),
    {
      id: "w1",
      version: 1,
      at: 2_000,
      kind: "activity",
      items: [
        { kind: "tool", text: "Read a.ts", tool: { id: "t1", title: "Read a.ts", kind: "read", status: "completed" } },
      ],
    } as AcpmuxRow,
    summary("s1", 41_000, { status: "cancelled" }),
  ];
  const row = footers(rows)[0]!;
  expect(row.folded).toBe(true);
  expect(row.resumable).toBe(true);
  expect(isEmptyFooter(row)).toBe(true);
  expect(layoutConversation([row], 720).heights[0]).toBe(0);
  expect(renderToStaticMarkup(<TurnFooter row={row} />)).toContain("cv-turn-actions--empty");
});

test("a stopped footer keeps resend off its action row", () => {
  const row = footers(stoppedTurn)[0]!;
  const html = renderToStaticMarkup(
    <TurnActionsContext.Provider
      value={{
        canSendPromptAgain: true,
        retry: async () => undefined,
        retryWith: {
          models: [
            { id: "a", name: "A" },
            { id: "b", name: "B" },
          ],
          retry: async () => undefined,
        },
      }}
    >
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );
  expect(html).not.toContain("cv-turn-retry");
  expect(html).not.toContain("cv-turn-continue");
});

test("an empty stopped footer does not move resend under the user prompt", () => {
  const html = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ retry: async () => undefined }}>
      <RetryTargetContext.Provider value={{ promptId: "p1" }}>
        <PromptActions row={prompt("p1", 1000)} text="Add retries" />
      </RetryTargetContext.Provider>
    </TurnActionsContext.Provider>,
  );
  expect(html).not.toContain("cv-message-retry");
});
