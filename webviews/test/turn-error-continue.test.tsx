// l10n-allow-file: test fixture prompts and errors, not shipped UI.
// Lawrence 2026-10-29, on a "Cmux is rate limited or out of capacity. Try again in a moment, or switch
// model." card under "Worked for 3m 42s" that offered Switch model, Set up cmux CodeRouter and Details:
// "should have a try again/continue type button here". The last failed turn's card leads with one
// way to go on: Continue when the turn had done work (or has no prompt to send again, as a turn a
// notice started), which resumes it with its context; Retry when nothing ran, which sends the prompt
// again. It leads for every failure that may pass (capacity, 503, network, a crash), it is the card's
// first tab stop so Return runs it, and the palette, CLI and MCP reach the same path (`continueAfterError`).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
const { errorRecovery, lastFailedTurn } = await import("../src/agent-session/acpmux/conversation/errorRecovery");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const CAPACITY = "API Error: 529 overloaded_error";
const prompt = (id: string, at: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "user",
  text: "Run the sidebar tests and fix what fails",
  ...fields,
});
const answer = (id: string, at: number): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "assistant",
  text: "Running them.",
});
const summary = (id: string, at: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "turnSummary",
  durationMs: 222_000,
  status: "failed",
  error: CAPACITY,
  ...fields,
});
const footers = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set(), { now: 300_000 }).filter((row) => row.kind === "turnSummary");

const card = () => host.querySelector<HTMLElement>(".cv-turn-error")!;
const actionLabels = () =>
  [...card().querySelectorAll(".cv-turn-error__actions > button, .cv-turn-error__actions > a")].map(
    (element) => element.textContent,
  );
const button = (label: string) =>
  [...card().querySelectorAll("button")].find((element) => element.textContent === label);

async function render(row: AcpmuxRow, actions: Record<string, unknown>) {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <TurnFooter row={row} />
      </TurnActionsContext.Provider>,
    ),
  );
}

test("a failed last turn that did work can be continued; one where nothing ran is retried", () => {
  const worked = footers([prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 223_000)]);
  expect(worked.map((row) => row.continuable)).toEqual([true]);
  const nothingRan = footers([prompt("p1", 1_000), summary("s1", 2_000)]);
  expect(nothingRan.map((row) => row.continuable)).toEqual([undefined]);
  expect(nothingRan[0]!.prompt).toBe("Run the sidebar tests and fix what fails");
});

test("a failed turn a notice started has no prompt to send again, so it continues", () => {
  const rows = footers([
    prompt("p1", 1_000, { incoming: { kind: "notice" } as AcpmuxRow["incoming"] }),
    summary("s1", 2_000),
  ]);
  expect(rows[0]!.prompt).toBeUndefined();
  expect(rows[0]!.continuable).toBe(true);
});

test("only the last turn continues, and a completed or stopped one never shows the error's Continue", () => {
  const rows = footers([
    prompt("p1", 1_000),
    answer("a1", 30_000),
    summary("s1", 40_000),
    prompt("p2", 50_000),
    answer("a2", 60_000),
    summary("s2", 70_000),
  ]);
  expect(rows.map((row) => row.continuable)).toEqual([undefined, true]);
  for (const status of ["completed", "cancelled"])
    expect(
      footers([prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 40_000, { status })])[0]!.continuable,
    ).toBeUndefined();
});

test("capacity: Continue leads as the filled button, left of Switch model, and resumes the turn", async () => {
  let resumed = 0;
  const [row] = footers([prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 223_000)]);
  await render(row!, {
    resume: async () => void (resumed += 1),
    retry: () => undefined,
    switchModel: () => undefined,
  });
  expect(card().getAttribute("data-failure-kind")).toBe("rate-limited");
  expect(actionLabels()).toEqual(["Continue", "Switch model"]);
  expect(card().querySelectorAll(".cv-turn-error__primary").length).toBe(1);
  expect(button("Continue")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Continue")!.getAttribute("aria-keyshortcuts")).toBe("Enter");
  await act(async () => button("Continue")!.click());
  expect(resumed).toBe(1);
});

test("capacity before anything ran: Retry leads and sends the prompt again", async () => {
  const retried: string[] = [];
  const [row] = footers([prompt("p1", 1_000), summary("s1", 2_000)]);
  await render(row!, {
    resume: async () => undefined,
    retry: (rowId: string, text: string) => retried.push(`${rowId}:${text}`),
    switchModel: () => undefined,
  });
  expect(actionLabels()).toEqual(["Retry", "Switch model"]);
  expect(button("Retry")!.classList.contains("cv-turn-error__primary")).toBe(true);
  await act(async () => button("Retry")!.click());
  expect(retried).toEqual(["p1:Run the sidebar tests and fix what fails"]);
});

test("Return on the focused card runs its lead action: the lead is the card's first tab stop", async () => {
  let resumed = 0;
  const [row] = footers([prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 223_000)]);
  await render(row!, { resume: async () => void (resumed += 1), switchModel: () => undefined });
  const first = card().querySelector<HTMLElement>("button, a[href], summary, [tabindex]")!;
  expect(first.textContent).toBe("Continue");
  expect(first.getAttribute("aria-keyshortcuts")).toBe("Enter");
  first.focus();
  expect(dom.window.document.activeElement).toBe(first);
  // Return on a focused button clicks it.
  await act(async () => first.click());
  expect(resumed).toBe(1);
  // One click goes on once: the lead waits for its send to settle.
  let settle: () => void = () => undefined;
  await render(row!, {
    resume: () => new Promise<void>((resolve) => (settle = () => resolve())),
    switchModel: () => undefined,
  });
  await act(async () => button("Continue")!.click());
  expect(button("Continue")!.disabled).toBe(true);
  await act(async () => settle());
  expect(button("Continue")!.disabled).toBe(false);
});

test("a sign-in failure offers no Continue: going on would fail the same way", async () => {
  const [row] = footers([
    prompt("p1", 1_000),
    answer("a1", 30_000),
    summary("s1", 40_000, { error: "Invalid API key · Please run /login" }),
  ]);
  await render(row!, { resume: async () => undefined, retry: () => undefined });
  expect(actionLabels()).not.toContain("Continue");
  expect(actionLabels()).not.toContain("Retry");
});

// The palette, CLI and MCP command runs the way on it finds directly, with no login before it: a
// sign-in failure retried that way fails the same way again. Only the card offers Retry there, beside
// its Sign in again, so the command keeps base's answer for sign-in: nothing to continue.
test("the palette, CLI and MCP command offers no retry for a sign-in failure, even with a login", async () => {
  const asked: string[] = [];
  const actions = {
    resume: async () => void asked.push("resume"),
    retry: () => void asked.push("resend"),
    retryFailed: async () => {
      asked.push("acpmux");
      return undefined;
    },
    reauthenticate: () => void asked.push("login"),
  };
  for (const error of ["Not logged in · Please run /login", "HTTP 401 Unauthorized"]) {
    const worked = turnView([prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 223_000, { error })], new Set(), {
      now: 300_000,
    });
    const fresh = turnView([prompt("p1", 1_000), summary("s1", 2_000, { error })], new Set(), { now: 300_000 });
    expect([error, errorRecovery(lastFailedTurn(worked)!, undefined, actions)]).toEqual([error, undefined]);
    expect([error, errorRecovery(lastFailedTurn(fresh)!, undefined, actions)]).toEqual([error, undefined]);
  }
  expect(asked).toEqual([]);
});

test("the palette, CLI and MCP command finds the same way on as the card", async () => {
  const calls: string[] = [];
  const actions = {
    resume: async () => void calls.push("resume"),
    retry: (rowId: string, text: string) => void calls.push(`retry:${rowId}:${text}`),
  };
  const worked = turnView([prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 223_000)], new Set(), {
    now: 300_000,
  });
  const recovery = errorRecovery(lastFailedTurn(worked)!, undefined, actions);
  expect(recovery?.label).toBe("continue");
  await recovery!.run();
  const fresh = turnView([prompt("p1", 1_000), summary("s1", 2_000)], new Set(), { now: 300_000 });
  const retry = errorRecovery(lastFailedTurn(fresh)!, undefined, actions);
  expect(retry?.label).toBe("retry");
  await retry!.run();
  expect(calls).toEqual(["resume", "retry:p1:Run the sidebar tests and fix what fails"]);
  // No failed last turn: nothing to continue.
  const done = turnView(
    [prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 40_000, { status: "completed", error: undefined })],
    new Set(),
    { now: 300_000 },
  );
  expect(lastFailedTurn(done)).toBeUndefined();
});

test("Continue and Retry go through acpmux's turn retry where the chat has one, with the right label", async () => {
  const asked: (string | undefined)[] = [];
  const actions = {
    resume: async () => void asked.push("resume"),
    retry: () => void asked.push("resend"),
    retryFailed: async (rowId: string | undefined) => {
      asked.push(`acpmux:${rowId}`);
      return undefined;
    },
  };
  const worked = turnView([prompt("p1", 1_000), answer("a1", 30_000), summary("s1", 223_000)], new Set(), {
    now: 300_000,
  });
  const goOn = errorRecovery(lastFailedTurn(worked)!, undefined, actions);
  expect(goOn?.label).toBe("continue");
  await goOn!.run();
  const fresh = turnView([prompt("p1", 1_000), summary("s1", 2_000)], new Set(), { now: 300_000 });
  const again = errorRecovery(lastFailedTurn(fresh)!, undefined, actions);
  expect(again?.label).toBe("retry");
  await again!.run();
  expect(asked).toEqual(["acpmux:p1", "acpmux:p1"]);
});
