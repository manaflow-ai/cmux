// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Continue after a stop. Leo, 2026-10-22: "and we should add a continue button if things were
// stopped, just like codex". The last turn, when the reader stopped it and no prompt followed,
// offers Continue on its footer; it sends the continue prompt through the composer's send, and goes
// once that prompt shows. Completed and failed turns, and older stopped turns, offer none.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { CONTINUE_PROMPT, resumeThrough, TurnActionsContext } from "./turnActions";
import { TurnFooter } from "./TurnRows";
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

test("a stopped last turn offers Continue", () => {
  expect(footers(stoppedTurn).map((row) => row.resumable)).toEqual([true]);
  // An interruption reads as a stop too.
  const interrupted = [prompt("p1", 1_000), summary("s1", 41_000, { status: "interrupted" })];
  expect(footers(interrupted).map((row) => row.resumable)).toEqual([true]);
});

test("completed and failed turns offer no Continue", () => {
  for (const status of ["completed", "failed", "error"]) {
    const rows = [prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 41_000, { status })];
    expect(footers(rows)[0]!.resumable).toBeUndefined();
  }
});

test("an older stopped turn offers no Continue; only the last one can", () => {
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

test("a stopped turn the agent went on from on its own offers no Continue once that turn ends", () => {
  const rows = [...stoppedTurn, answer("a2", 50_000), summary("s2", 51_000, { status: "completed" })];
  expect(footers(rows).every((row) => !row.resumable)).toBe(true);
});

test("a turn the agent started on its own and the reader stopped offers Continue on its own footer", () => {
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
    // Its version moves, so the memoized footer redraws with the button.
    expect(second!.version).not.toBe(1);
    // A prompt sent after it takes the button away again.
    const sent = footers([...rows, prompt("p2", 60_000, { pending: true })]);
    expect(sent.every((row) => !row.resumable)).toBe(true);
  }
});

// Review at c3ec4170 (P2): with daemon turn ids, the agent's own turn in the tail names a turn other
// than the prompt's; that is what makes it the agent's, and the reader's Stop of it still offers Continue.
test("an agent-started turn with its own turn id, stopped by the reader, offers Continue", () => {
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

test("a turn a prompt sent now ended is not a stop, so it offers no Continue", () => {
  const rows = [prompt("p1", 1_000), summary("s1", 41_000, { status: "cancelled", continued: true })];
  expect(footers(rows).every((row) => !row.resumable)).toBe(true);
});

test("Continue goes once the next prompt is sent, and while the new turn runs", () => {
  // The continue prompt is sent and not yet taken: it waits under the stopped turn.
  const sending = [...stoppedTurn, prompt("p2", 50_000, { text: CONTINUE_PROMPT, pending: true })];
  expect(footers(sending)[0]!.resumable).toBeUndefined();
  // Taken: a new turn has started, still running.
  const started = [...stoppedTurn, prompt("p2", 50_000, { text: CONTINUE_PROMPT })];
  expect(footers(started, true)[0]!.resumable).toBeUndefined();
  // The stopped turn itself running again (the agent went on after its summary).
  expect(footers(stoppedTurn, true)[0]!.resumable).toBeUndefined();
});

test("the footer's version changes when Continue comes or goes, so memoized rows redraw", () => {
  const offered = footers(stoppedTurn)[0]!;
  const gone = footers([...stoppedTurn, prompt("p2", 50_000, { pending: true })])[0]!;
  expect(offered.version).not.toBe(gone.version);
});

test("the footer draws Continue only with the action, and shows at rest", () => {
  const row = footers(stoppedTurn)[0]!;
  const withResume = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ resume: async () => undefined }}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );
  // In whatever language the table is in (another test file may have switched it).
  expect(withResume).toContain(translate("turn.continue"));
  expect(withResume).toContain("cv-turn-actions--resumable");
  expect(withResume).toContain(translate("turn.stopped", { time: "40s" }));
  // No action (a View Only chat, or not connected): no button.
  expect(renderToStaticMarkup(<TurnFooter row={row} />)).not.toContain("cv-turn-continue");
  // There a folded stopped turn with nothing else to show keeps no line for it.
  const folded = { ...row, folded: true, text: undefined };
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

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

test("clicking Continue sends the continue prompt through chat.send", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const resume = resumeThrough(async (method, params) => {
    calls.push([method, params]);
  });
  const container = await render(
    <TurnActionsContext.Provider value={{ resume }}>
      <TurnFooter row={footers(stoppedTurn)[0]!} />
    </TurnActionsContext.Provider>,
  );
  const button = container.querySelector<HTMLButtonElement>(".cv-turn-continue")!;
  expect(button.textContent).toBe(translate("turn.continue"));
  await act(async () => button.click());
  expect(calls).toEqual([["chat.send", { text: CONTINUE_PROMPT }]]);
});

test("a refused continue send is swallowed; its row says why", async () => {
  const resume = resumeThrough(() => Promise.reject(new Error("refused")));
  await expect(resume()).resolves.toBeUndefined();
});

test("a second click while the first send is in flight sends nothing more", async () => {
  const calls: string[] = [];
  let settle: () => void = () => undefined;
  const resume = resumeThrough((method) => {
    calls.push(method);
    return new Promise<void>((resolve) => (settle = resolve));
  });
  const container = await render(
    <TurnActionsContext.Provider value={{ resume }}>
      <TurnFooter row={footers(stoppedTurn)[0]!} />
    </TurnActionsContext.Provider>,
  );
  const button = container.querySelector<HTMLButtonElement>(".cv-turn-continue")!;
  await act(async () => button.click());
  await act(async () => button.click());
  expect(calls).toEqual(["chat.send"]);
  expect(button.disabled).toBe(true);
  await act(async () => settle());
  expect(button.disabled).toBe(false);
});

test("a stopped last turn whose work folds keeps its line for Continue", () => {
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
  expect(isEmptyFooter(row)).toBe(false);
});
