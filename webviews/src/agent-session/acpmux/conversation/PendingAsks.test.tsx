// l10n-allow-file: test fixtures.
// A question still waiting on the person, pinned above the composer (PendingAsks.tsx): its answer
// goes as the person's message, a send that fails says so and keeps the buttons, and Dismiss is
// kept for the chat across a reload (waitingAskStore.ts).
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { nextStepAsk, pinnedAsk } from "./nextStepAsk";
import { PendingAsks } from "./PendingAsks";
import {
  answeredAsks,
  askKey,
  claimedReply,
  dismissAsk,
  dismissedAsks,
  resetAnswerClaims,
  shownAsks,
  withAnswered,
} from "./waitingAskStore";
import { NextStepRow } from "../rows/NextStepRow";
import { TurnActionsContext } from "./turnActions";
import { NEXT_STEP, turnView, turnViewFrom, waitingAsks } from "./turns";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  resetAnswerClaims();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const card = (at: number, text: string): AcpmuxRow =>
  ({ id: `nextStep-${at}`, version: 1, at, kind: "nextStep", nextStep: { ask: nextStepAsk(text)! } }) as AcpmuxRow;
const asked = card(1_000, "[taste] Which look should ship?\n- Box\n- Inline");

const buttons = (container: HTMLElement) => [...container.querySelectorAll("button")];
const named = (container: HTMLElement, text: string) => buttons(container).find((b) => b.textContent?.includes(text))!;

// Leo, 2026-11-08, on a bare "Not now" bubble: "wait this thing should've shown that it was a
// reply to an ask from you". The answer quotes the ask and who asked, as Quote in Reply quotes.
test("an answer goes as the person's reply, quoting the ask and who asked", async () => {
  const sent: string[] = [];
  const container = await render(
    <PendingAsks
      asks={[asked]}
      onAnswer={(text) => (sent.push(text), Promise.resolve())}
      onDismiss={() => undefined}
      asker="Claude Code"
    />,
  );
  expect(container.textContent).toContain("Which look should ship?");
  await act(async () => named(container, "Inline").click());
  expect(sent).toEqual(["> Claude Code: Which look should ship?\n\nInline"]);
});

test("a send that fails says so and keeps the answers", async () => {
  const container = await render(
    <PendingAsks asks={[asked]} onAnswer={() => Promise.reject(new Error("refused"))} onDismiss={() => undefined} />,
  );
  await act(async () => named(container, "Box").click());
  expect(container.querySelector("output")).not.toBeNull();
  expect(named(container, "Box").disabled).toBe(false);
});

test("Dismiss names the card, and the chat keeps it across a reload", async () => {
  const dismissed: string[] = [];
  const container = await render(
    <PendingAsks asks={[asked]} onAnswer={() => Promise.resolve()} onDismiss={(key) => dismissed.push(key)} />,
  );
  const dismiss = container.querySelector<HTMLButtonElement>(".acpmux-pending-ask .acpmux-next-step__bar .ui-dismiss")!;
  await act(async () => dismiss.click());
  expect(dismissed).toEqual([askKey(asked)]);
  dismissAsk("s1", askKey(asked));
  // Read back as a reload reads it: the card leaves the pinned list in that chat only.
  expect(shownAsks([asked], dismissedAsks("s1"))).toEqual([]);
  expect(shownAsks([asked], dismissedAsks("s2"))).toEqual([asked]);
});

// The order the coordinator's chat logged on 2026-11-06: its turn ended on a tagged question, a
// peer agent's message started a turn of its own, then the person answered through the card. The
// answer never reached acpmux: the card had gone back into the prose.
test("question, a peer message's turn, then the answer through the card reaches the chat", async () => {
  let at = 0;
  const line = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}) =>
    ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
  const text = "Read the lock path.\n\n[taste] Do you mean computer use, still working while the Mac is locked?";
  const rows = [
    line("p1", "user", { text: "Why does it stop on lock?" }),
    line("a1", "assistant", { text }),
    line("s1", "turnSummary", { status: "completed" }),
    line("m1", "user", {
      text: "Pushed abc123.",
      untyped: true,
      incoming: { kind: "message", message: { name: "peer-lane", text: "Pushed abc123.", raw: "Pushed abc123." } },
    } as Partial<AcpmuxRow>),
    line("a2", "assistant", { text: "Noted." }),
    line("s2", "turnSummary", { status: "completed" }),
  ];
  const inTranscript = turnView(rows, new Set()).find((row) => row.kind === NEXT_STEP);
  expect(inTranscript).toBeDefined();
  const pinned = waitingAsks(turnViewFrom(rows, new Set()));
  expect(pinned).toHaveLength(1);
  const sent: string[] = [];
  const answer = (said: string) => (sent.push(said), Promise.resolve());
  const container = await render(
    <TurnActionsContext.Provider value={{ answer, asker: "Codex" }}>
      <NextStepRow row={inTranscript!} onToggleActivity={() => undefined} expanded={false} />
      <PendingAsks asks={pinned} onAnswer={answer} onDismiss={() => undefined} asker="Codex" />
    </TurnActionsContext.Provider>,
  );
  const [inline, pinnedYes] = buttons(container).filter((b) => b.textContent?.includes("Yes"));
  await act(async () => inline!.click());
  expect(pinnedYes!.isConnected && pinnedYes!.closest(".acpmux-next-step__answers")).toBeFalsy();
  await act(async () => pinnedYes!.click());
  const reply = "> Codex: Do you mean computer use, still working while the Mac is locked?\n\nYes";
  // The two copies share the card's key: the first click answers both, so the answer goes once.
  expect(sent).toEqual([reply]);
  // Once sent, the person's prompt settles the card in the transcript and leaves the pinned list.
  const answered = [...rows, line("p2", "user", { text: reply })];
  expect(turnView(answered, new Set()).find((row) => row.kind === NEXT_STEP)?.nextStep?.answer).toBe("Yes");
  expect(waitingAsks(turnViewFrom(answered, new Set()))).toEqual([]);
});

// Leo, 2026-11-17, after clicking "Plugged in" on a pinned ask while a turn ran: "after i click the
// behaviour is very weird". The card kept both buttons and the queue row behind the turn read
// "> Claude Code: [physical] Plug your iPhone...": no prompt row settles a card while its answer
// waits in the queue, and the row showed the prompt's quote of the ask.
test("a click answers the card in the same frame, and it stays answered while the answer is queued", async () => {
  resetAnswerClaims();
  const physical = card(5_000, "[physical] Plug your iPhone into the Mac?\n- Plugged in\n- Not now");
  let release: () => void = () => undefined;
  const sent: string[] = [];
  const container = await render(
    <PendingAsks
      asks={[physical]}
      onAnswer={(text) => (sent.push(text), new Promise<void>((resolve) => (release = resolve)))}
      onDismiss={() => undefined}
      asker="Claude Code"
    />,
  );
  await act(async () => named(container, "Plugged in").click());
  // On its way: the pinned card leaves, header and all, and leaves the hat too.
  expect(container.querySelectorAll(".acpmux-next-step__answer")).toHaveLength(0);
  expect(container.querySelector(".acpmux-pending-ask")).toBeNull();
  expect(answeredAsks().has(askKey(physical))).toBe(true);
  expect(shownAsks([physical], withAnswered(new Set(), answeredAsks()))).toEqual([]);
  // Sent, and waiting in the queue behind the running turn: still gone.
  await act(async () => release());
  expect(container.querySelectorAll(".acpmux-next-step__answer")).toHaveLength(0);
  expect(answeredAsks().has(askKey(physical))).toBe(true);
  // The queue row reads the answer, not the quote of the ask; any other quoted prompt reads as it is.
  expect(claimedReply(sent[0]!)).toBe("Plugged in");
  expect(claimedReply("> some selection\n\nPlugged in")).toBeUndefined();
});

test("a send that fails brings the card back with its buttons", async () => {
  resetAnswerClaims();
  const failing = card(9_000, "[taste] Which colour?\n- Red\n- Blue");
  const container = await render(
    <PendingAsks asks={[failing]} onAnswer={() => Promise.reject(new Error("refused"))} onDismiss={() => undefined} />,
  );
  await act(async () => named(container, "Red").click());
  expect(container.querySelectorAll(".acpmux-next-step__answer")).toHaveLength(2);
  expect(answeredAsks().has(askKey(failing))).toBe(false);
});

// The pinned copy leaves while its answer goes, so a typed answer that fails comes back with its words.
test("a typed answer that fails comes back with its words", async () => {
  let reject: (error: Error) => void = () => undefined;
  const container = await render(
    <PendingAsks
      asks={[asked]}
      onAnswer={() => new Promise((_, fail) => (reject = fail))}
      onDismiss={() => undefined}
    />,
  );
  const field = () => container.querySelector<HTMLInputElement>(".acpmux-next-step__other input")!;
  const window = dom!.window;
  await act(async () => {
    Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!.call(field(), "Both");
    field().dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    field().dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(container.querySelector(".acpmux-next-step__other")).toBeNull();
  await act(async () => reject(new Error("refused")));
  expect(field().value).toBe("Both");
  expect(container.querySelector("output")).not.toBeNull();
});

// A pane that cannot send (View Only) still shows the pinned card: the same card read only, with its
// answers, the reason, and its close.
test("a pinned card in a pane that cannot send is the same card read only, and keeps its close", async () => {
  const dismissed: string[] = [];
  const container = await render(
    <PendingAsks asks={[asked]} blocked="watching" onDismiss={(key) => dismissed.push(key)} />,
  );
  expect([...container.querySelectorAll("li.acpmux-next-step__answer")].map((row) => row.textContent)).toEqual([
    "1Box",
    "2Inline",
  ]);
  expect(container.querySelector(".acpmux-next-step__reason")?.textContent).toBe("Take over to answer");
  expect(container.querySelector("input")).toBeNull();
  // The close is the card's only button.
  expect(container.querySelectorAll(".acpmux-pending-ask button")).toHaveLength(1);
  const dismiss = container.querySelector<HTMLButtonElement>(".acpmux-pending-ask .acpmux-next-step__bar .ui-dismiss")!;
  await act(async () => dismiss.click());
  expect(dismissed).toEqual([askKey(asked)]);
});

test("the pinned copy's ask is one object per ask, without its recap, so the card's memo holds", () => {
  const ask = nextStepAsk(
    "Done: the fix is in.\n\n[taste] Should I allow GitHub-hosted runners until the pool is back?",
  )!;
  const withRecap = { ...ask, recap: "Done: the fix is in." };
  expect(pinnedAsk(withRecap)).toBe(pinnedAsk(withRecap));
  expect("recap" in pinnedAsk(withRecap)).toBe(false);
  expect(pinnedAsk(withRecap).question).toBe(ask.question);
});
