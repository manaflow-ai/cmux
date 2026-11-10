// A failed turn's Retry sent the whole prompt again as a new message, even though acpmux serves its
// own turn retry (`_acpmux/retry`, `turn-retry-v1`): that one continues a turn the model had started,
// takes over a retry acpmux already has waiting instead of racing it, and lets the prompts the failed
// turn held go on once it completes. A long chat's failed turn reran work and held its queue. The
// failed turn's Retry now asks acpmux first, and sends the prompt again only where acpmux cannot.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { RetryNotSent, resendToOwner, retryFailedTurn } from "../src/agent-session/acpmux/conversation/turnRetry";
import { RETRY_METHOD, TURN_RETRY } from "../src/agent-session/acpmux/subagents/retryState";
import { teardownDom } from "./support/domTeardown";

const refusal = (reason: string, why?: string) =>
  Object.assign(new Error(`${reason}: refused`), { reason, ...(why ? { data: { why } } : {}) });

const deps = (
  answer: () => Promise<unknown>,
  capabilities: ReadonlySet<string> | undefined = new Set([TURN_RETRY]),
) => {
  const calls: string[] = [];
  return {
    calls,
    deps: {
      sessionId: "chat-1",
      capabilities,
      request: (method: string, params: Record<string, unknown>) => {
        calls.push(`${method} ${JSON.stringify(params)}`);
        return answer();
      },
      resend: () => {
        calls.push("resend");
        return Promise.resolve();
      },
    },
  };
};

test("a failed turn's Retry asks acpmux to retry the chat's turn, and sends nothing itself", async () => {
  const { calls, deps: d } = deps(() => Promise.resolve({ promptId: "p~resume-1", kind: "turn" }));
  expect(await retryFailedTurn(d)).toBeUndefined();
  expect(calls).toEqual([`${RETRY_METHOD} {"sessionId":"chat-1"}`]);
});

test("where acpmux cannot retry the turn, Retry sends the prompt again", async () => {
  // No turn retry served.
  const old = deps(() => Promise.resolve(), new Set());
  expect(await retryFailedTurn(old.deps)).toBeUndefined();
  expect(old.calls).toEqual(["resend"]);
  // A daemon that names no capabilities, and does not know the method.
  const unknown = deps(() => Promise.reject(Object.assign(new Error("Method not found"), { code: -32601 })), undefined);
  expect(await retryFailedTurn(unknown.deps)).toBeUndefined();
  expect(unknown.calls).toEqual([`${RETRY_METHOD} {"sessionId":"chat-1"}`, "resend"]);
});

test("a turn another retry already ran to the end is not sent again", async () => {
  // An automatic retry, or another pane's, finished first: acpmux's last turn no longer failed.
  const nothing = deps(() => Promise.reject(refusal("retry.nothing_failed")));
  expect(await retryFailedTurn(nothing.deps)).toBe("retry.nothingFailed");
  expect(nothing.calls.includes("resend")).toBe(false);
});

test("an old daemon with no prompt to send again says Retry could not run", async () => {
  const { calls, deps: d } = deps(() => Promise.resolve(), new Set());
  expect(await retryFailedTurn({ ...d, resend: undefined })).toBe("retry.failed");
  expect(calls).toEqual([]);
});

test("a refusal that a second send would double says why, and sends nothing", async () => {
  for (const [error, note] of [
    [refusal("retry.busy"), "retry.busy"],
    [refusal("retry.nothing_failed", "running"), "retry.running"],
    [refusal("retry.stopped"), "retry.gone"],
    [new Error("timed out"), "retry.failed"],
  ] as const) {
    const { calls, deps: d } = deps(() => Promise.reject(error));
    expect([String(error.message), await retryFailedTurn(d)]).toEqual([String(error.message), note]);
    expect(calls.includes("resend")).toBe(false);
  }
});

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

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const failed = {
  id: "summary-2",
  version: 1,
  at: Date.now(),
  kind: "turnSummary",
  seq: 2,
  status: "failed",
  durationMs: 662_000,
  error: "agent process closed",
  prompt: "Run the sidebar tests and fix what fails",
  retryRowId: "user-1",
  retryable: true,
} as const;
const card = () => host.querySelector(".cv-turn-error")!;
const cardRetry = () => [...card().querySelectorAll("button")].find((element) => element.textContent === "Retry")!;
const footerRetry = () => host.querySelector<HTMLButtonElement>('.cv-turn-actions button[aria-label="Retry"]')!;

test("the failed turn's card and footer Retry use the failed turn's retry, never a plain resend", async () => {
  const sent: string[] = [];
  const asked: (string | undefined)[] = [];
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          retry: (rowId) => sent.push(rowId),
          retryFailed: (rowId) => {
            asked.push(rowId);
            return Promise.resolve(undefined);
          },
        }}
      >
        <TurnFooter row={failed} />
      </TurnActionsContext.Provider>,
    ),
  );
  await act(async () => cardRetry().click());
  await act(async () => footerRetry().click());
  expect(asked).toEqual(["user-1", "user-1"]);
  expect(sent).toEqual([]);
});

test("a refused retry says why on the card, and Retry waits while one is in flight", async () => {
  let settle: (note: "retry.busy") => void = () => undefined;
  let asks = 0;
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          retry: () => undefined,
          retryFailed: () => {
            asks += 1;
            return new Promise((resolve) => (settle = resolve));
          },
        }}
      >
        <TurnFooter row={failed} />
      </TurnActionsContext.Provider>,
    ),
  );
  await act(async () => cardRetry().click());
  expect(cardRetry().hasAttribute("disabled")).toBe(true);
  await act(async () => cardRetry().click());
  expect(asks).toBe(1);
  await act(async () => settle("retry.busy"));
  expect(cardRetry().hasAttribute("disabled")).toBe(false);
  expect(card().querySelector(".cv-turn-error__note")!.textContent).toBe("Busy, try again shortly");
});

test("an attempt acpmux sent that failed again still offers Retry, and the turn before it does not", async () => {
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  let at = 0;
  const row = (id: string, kind: string, extra: Record<string, unknown> = {}) =>
    ({ id, kind, version: 1, at: (at += 1_000), ...extra }) as Parameters<typeof turnView>[0][number];
  const rows = [
    row("user-1", "user", { text: "Run the sidebar tests" }),
    row("turn-2", "turnSummary", { status: "failed", error: "agent process closed", durationMs: 1_000 }),
    // acpmux's own retry: its prompt row is bookkeeping and draws nothing.
    row("user-3", "user", { text: "", incoming: { kind: "hidden" } }),
    row("turn-4", "turnSummary", { status: "failed", error: "agent process closed", durationMs: 1_000 }),
  ];
  const summaries = turnView(rows, new Set(), { now: 10_000 }).filter((shaped) => shaped.kind === "turnSummary");
  expect(summaries.map((summary) => [summary.id, summary.retryable === true])).toEqual([
    ["turn-2", false],
    ["turn-4", true],
  ]);
  const last = summaries.at(-1)!;
  const asked: (string | undefined)[] = [];
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          retry: () => undefined,
          retryFailed: (rowId) => {
            asked.push(rowId);
            return Promise.resolve(undefined);
          },
        }}
      >
        <TurnFooter row={last} />
      </TurnActionsContext.Provider>,
    ),
  );
  await act(async () => cardRetry().click());
  expect(asked).toEqual([last.retryRowId]);
});

// An old daemon's fallback restores the prompt's attachments (`resendPrompt`, which may ask acpmux)
// before it sends. A chat switch during that wait must not send the failed prompt to the next chat.
test("the fallback send checks the chat and client again after the prompt is restored", async () => {
  const run = async (change: (state: { owns: boolean; client: object }) => void) => {
    const client = {};
    const state = { owns: true, client };
    type Draft = { input: string; attachments: never[] };
    let restored!: (draft: Draft) => void;
    const sent: string[] = [];
    const going = resendToOwner({
      client,
      currentClient: () => state.client,
      owns: () => state.owns,
      restore: () => new Promise<Draft>((resolve) => (restored = resolve)),
      send: (draft) => {
        sent.push(draft.input);
        return Promise.resolve();
      },
    });
    change(state);
    restored({ input: "fix the build", attachments: [] });
    // One that sent nothing rejects (RetryNotSent), so the card says Retry could not run.
    const went = await going.then(
      () => true,
      (error: unknown) => (error instanceof RetryNotSent ? false : Promise.reject(error)),
    );
    return [went, sent] as const;
  };
  expect(await run(() => undefined)).toEqual([true, ["fix the build"]]);
  expect(await run((state) => (state.owns = false))).toEqual([false, []]);
  expect(await run((state) => (state.client = {}))).toEqual([false, []]);
});

// cmux#34369: a Retry whose fallback send reached no chat settled as sent, so the card said nothing
// and the button came back as if the click had not happened.
test("a fallback send that reaches no chat says Retry could not run", async () => {
  const { deps: d } = deps(() => Promise.reject(Object.assign(new Error("no method"), { code: -32601 })));
  expect(await retryFailedTurn({ ...d, resend: () => Promise.reject(new RetryNotSent()) })).toBe("retry.failed");
});

// cmux#34369: acpmux took the Retry, and the card came back at once looking untouched; during a
// gateway outage the retried attempt failed again as fast, so the click read as doing nothing. The
// card says Retrying… from the click until the attempt reaches the chat and changes the row. The
// button waits only while the request is in flight: a second click is acpmux's to refuse.
test("a Retry acpmux took says Retrying… until its attempt reaches the chat", async () => {
  const answers: ((note: "retry.busy" | undefined) => void)[] = [];
  const draw = (row: Parameters<typeof TurnFooter>[0]["row"]) =>
    act(async () =>
      root.render(
        <TurnActionsContext.Provider
          value={{
            retry: () => undefined,
            retryFailed: () => new Promise((resolve) => answers.push(resolve)),
          }}
        >
          {/* Keyed by the row's id, as the transcript draws it: a new failure is a new footer. */}
          <TurnFooter key={row.id} row={row} />
        </TurnActionsContext.Provider>,
      ),
    );
  const note = () => card().querySelector(".cv-turn-error__note")?.textContent;
  await draw({ ...failed, id: "summary-retried" });
  expect(note()).toBeUndefined();
  await act(async () => cardRetry().click());
  expect([note(), cardRetry().hasAttribute("disabled"), footerRetry().hasAttribute("disabled")]).toEqual([
    "Retrying…",
    true,
    true,
  ]);
  // acpmux answered: the attempt is on its way, and the card keeps saying so.
  await act(async () => answers[0]!(undefined));
  expect([note(), cardRetry().hasAttribute("disabled")]).toEqual(["Retrying…", false]);
  // A second click while it runs is acpmux's to refuse, and the card says why.
  await act(async () => footerRetry().click());
  await act(async () => answers[1]!("retry.busy"));
  expect(note()).toBe("Busy, try again shortly");
  // A Retry taken again, then the attempt reached the chat: the row changed and the note is gone.
  await act(async () => cardRetry().click());
  await act(async () => answers[2]!(undefined));
  expect(note()).toBe("Retrying…");
  await draw({ ...failed, id: "summary-retried", version: failed.version + 1 });
  expect([note(), cardRetry().hasAttribute("disabled")]).toEqual([undefined, false]);
  expect(answers.length).toBe(3);
});

// cmux#34369: a Retry acpmux ran that failed again (a gateway still down) drew the same card as
// before, so the click read as doing nothing. The attempt's card says it failed again.
test("a retried attempt that failed too says so on its card, and the first failure does not", async () => {
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  let at = 0;
  const row = (id: string, kind: string, extra: Record<string, unknown> = {}) =>
    ({ id, kind, version: 1, at: (at += 1_000), ...extra }) as Parameters<typeof turnView>[0][number];
  const error = "API Error: Connection error.";
  const rows = [
    row("user-1", "user", { text: "Run the sidebar tests", promptId: "p1" }),
    row("turn-2", "turnSummary", { status: "failed", error, durationMs: 1_000 }),
    row("user-3", "user", { text: "", incoming: { kind: "hidden" }, promptId: "p1~resume-1" }),
    row("turn-4", "turnSummary", { status: "failed", error, durationMs: 1_000 }),
  ];
  const summaries = turnView(rows, new Set(), { now: 10_000 }).filter((shaped) => shaped.kind === "turnSummary");
  expect(summaries.map((summary) => [summary.id, summary.failedAgain === true])).toEqual([
    ["turn-2", false],
    ["turn-4", true],
  ]);
  const note = () => card().querySelector(".cv-turn-error__note")?.textContent;
  for (const [summary, expected] of [
    [summaries[0]!, undefined],
    [summaries[1]!, "Failed again after retrying"],
  ] as const) {
    await act(async () =>
      root.render(
        <TurnActionsContext.Provider value={{ retry: () => undefined, retryFailed: () => Promise.resolve(undefined) }}>
          <TurnFooter key={summary.id} row={summary} />
        </TurnActionsContext.Provider>,
      ),
    );
    expect(note()).toBe(expected);
  }
});

// cmux#34369: a chat without acpmux's retry (View Only, a read-only pane) sends the prompt again;
// a send that did not go settled as sent, and the card said nothing.
test("a plain resend that did not go says Retry could not run", async () => {
  const { errorRecovery } = await import("../src/agent-session/acpmux/conversation/errorRecovery");
  const row = { ...failed, id: "summary-resend" } as Parameters<typeof errorRecovery>[0];
  const recovery = (sent: boolean) => errorRecovery(row, undefined, { retry: () => Promise.resolve(sent) });
  expect(await recovery(false)!.run()).toBe("retry.failed");
  expect(await recovery(true)!.run()).toBeUndefined();
  // A provider that names no outcome still counts as sent.
  expect(await errorRecovery(row, undefined, { retry: () => undefined })!.run()).toBeUndefined();
});

// cmux#34369 review: a fallback Retry (no acpmux turn retry) sends through `chat.send`, which settles
// only when the turn it starts ends. Waiting on it kept Retrying… and a disabled Retry up for the
// whole retried turn, and called a turn that ran and then failed "Couldn't retry". It settles once
// acpmux took the prompt; a send it took whose turn then failed is still sent.
test("a fallback send settles once acpmux took it, not when its turn ends", async () => {
  const { sendUntilTaken } = await import("../src/agent-session/acpmux/conversation/turnRetry");
  let settled = false;
  let accept: () => void = () => undefined;
  let endTurn: (value?: unknown) => void = () => undefined;
  let failTurn: (error: unknown) => void = () => undefined;
  const going = sendUntilTaken((accepted) => {
    accept = accepted;
    return new Promise((resolve, reject) => ((endTurn = resolve), (failTurn = reject)));
  }).then(() => (settled = true));
  await Promise.resolve();
  expect(settled).toBe(false);
  accept();
  await going;
  expect(settled).toBe(true);
  endTurn();
  // Taken, then its turn failed: sent. Refused before acpmux took it: not sent.
  const taken = sendUntilTaken(() => Promise.reject(Object.assign(new Error("turn failed"), { taken: true })));
  expect(await taken.then(() => "sent")).toBe("sent");
  const refused = sendUntilTaken(() => Promise.reject(new Error("refused")));
  expect(
    await refused.then(
      () => "sent",
      () => "not sent",
    ),
  ).toBe("not sent");
  failTurn(new Error("late"));
});

// cmux#34369 review: Retrying… belongs to the row that was clicked. Once the attempt reaches the chat
// and changes that row, the note goes even if the request is still in flight.
test("Retrying… goes once the clicked row changes, even while the request is in flight", async () => {
  const draw = (row: Parameters<typeof TurnFooter>[0]["row"]) =>
    act(async () =>
      root.render(
        <TurnActionsContext.Provider
          value={{ retry: () => undefined, retryFailed: () => new Promise(() => undefined) }}
        >
          <TurnFooter key={row.id} row={row} />
        </TurnActionsContext.Provider>,
      ),
    );
  const note = () => card().querySelector(".cv-turn-error__note")?.textContent;
  await draw({ ...failed, id: "summary-in-flight" });
  await act(async () => cardRetry().click());
  expect(note()).toBe("Retrying…");
  await draw({ ...failed, id: "summary-in-flight", version: failed.version + 1 });
  expect(note()).toBeUndefined();
});

// cmux#34369 review: the footer Retry of a chat without acpmux's turn retry sent the prompt again
// with no feedback, and a send that did not go read as nothing happening.
test("the footer's plain resend says Retrying…, and Couldn't retry when the send did not go", async () => {
  let answer: (sent: boolean) => void = () => undefined;
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => new Promise<boolean>((resolve) => (answer = resolve)) }}>
        <TurnFooter key="summary-plain" row={{ ...failed, id: "summary-plain" }} />
      </TurnActionsContext.Provider>,
    ),
  );
  const note = () => card().querySelector(".cv-turn-error__note")?.textContent;
  await act(async () => footerRetry().click());
  expect([note(), footerRetry().hasAttribute("disabled")]).toEqual(["Retrying…", true]);
  await act(async () => answer(false));
  expect([note(), footerRetry().hasAttribute("disabled")]).toEqual(["Couldn't retry", false]);
});
