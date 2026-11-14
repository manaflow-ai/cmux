// A sent prompt's row says one thing about its delivery at a time (Leo, 2026-11-11: "what's up with
// this still sending thing? What's the point of that? But, like, it already, like, shows that it's
// sent. So this is incongruous."). Before, a slow send drew "Still sending" beside a bubble whose
// footer already read "just now" with Copy and Retry, and a lost one added a free "Not sent yet"
// line under it. Now the footer's time slot holds either the prompt's age (it landed) or its one
// pending sentence (on its way), never both, and a failed prompt draws no sent footer, only its
// card with Retry.
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, PromptDelivery } from "../model";
import { translate } from "../i18n";
import { PresentationContext } from "./presentationContextModel";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { DeliveryFailure } from "./PromptDelivery";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
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
});

async function render(row: AcpmuxRow): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <PresentationContext.Provider value="messages">
        <TurnActionsContext.Provider value={{ retry: () => {} }}>
          <UserBubble row={row} text={row.text ?? ""} />
          <DeliveryFailure row={row} />
        </TurnActionsContext.Provider>
      </PresentationContext.Provider>,
    );
  });
  return container;
}

const prompt = (delivery: Partial<PromptDelivery> & Pick<PromptDelivery, "state">, extra: Partial<AcpmuxRow> = {}) => {
  const row: AcpmuxRow = {
    id: "local-p1",
    version: 1,
    kind: "user",
    at: Date.now(),
    text: "Then open a PR",
    ...(delivery.state === "sending" ? { pending: true } : {}),
    delivery: { promptId: "p1", sessionId: "s1", sentAt: Date.now(), ...delivery },
    ...extra,
  };
  return row;
};

/// What the row says about its delivery: its age (sent), its pending sentence, and the words.
function said(container: HTMLElement) {
  const text = container.textContent ?? "";
  return {
    age: container.querySelectorAll("time.cv-user__time").length,
    pending: container.querySelectorAll(".cv-user__pending-state").length,
    stillSending: text.includes("Still sending") || container.querySelector(".cv-user__delivery") !== null,
    notSentYet: text.includes(translate("prompt.failure.hostAway")),
    retry: [...container.querySelectorAll("button")].some((button) => button.textContent === translate("turn.retry")),
  };
}

test("a fast send never says it is sending: its footer has its age only", async () => {
  const container = await render(prompt({ state: "sending", sentAt: Date.now() }));
  const state = said(container);
  expect(state.pending).toBe(0);
  expect(state.stillSending).toBe(false);
  expect(state.age).toBe(1);
});

test("a slow acknowledgement shows one pending state, in the time slot, and no age beside it", async () => {
  const container = await render(prompt({ state: "sending", sentAt: Date.now() - 15_000, slow: true }));
  const state = said(container);
  expect(state.pending).toBe(1);
  expect(state.age).toBe(0);
  expect(state.stillSending).toBe(false);
  expect(state.notSentYet).toBe(false);
  expect(container.querySelector(".cv-user__actions--pending")).not.toBeNull();
  expect(container.querySelector(".cv-user__pending-state")?.getAttribute("aria-label")).toBe(
    translate("prompt.delivery.sending"),
  );
});

test("a steer on its way into the running turn says it is queued behind it, never Not sent", async () => {
  const container = await render(prompt({ state: "sending", sentAt: Date.now() - 5_000, queued: true }));
  expect(container.querySelector(".cv-user__pending-state")?.getAttribute("aria-label")).toBe(
    translate("prompt.delivery.queued"),
  );
  expect(translate("prompt.delivery.queued")).toBe("Queued, sends when the current turn ends");
  expect(said(container).notSentYet).toBe(false);
});

test("a send held while the agent service reconnects says so at once, in the same slot", async () => {
  const container = await render(prompt({ state: "sending", sentAt: Date.now(), waitingForHost: true }));
  expect(container.querySelector(".cv-user__pending-state")?.getAttribute("aria-label")).toBe(
    translate("prompt.delivery.whenReady"),
  );
  expect(said(container).age).toBe(0);
});

test("a failed send shows Retry on its card and no sent footer", async () => {
  const container = await render(
    prompt(
      { state: "failed", code: "native.timed_out", hop: "connection", failedAt: Date.now() },
      { failed: true, pending: false, error: translate("prompt.failure.hostAway") },
    ),
  );
  const state = said(container);
  expect(state.retry).toBe(true);
  expect(state.age).toBe(0);
  expect(state.pending).toBe(0);
});

test("no delivery state draws sent and still sending together", async () => {
  const now = Date.now();
  const states: Array<[Partial<PromptDelivery> & Pick<PromptDelivery, "state">, Partial<AcpmuxRow>]> = [
    [{ state: "sending", sentAt: now }, {}],
    [{ state: "sending", sentAt: now - 2_000 }, {}],
    [{ state: "sending", sentAt: now - 30_000, slow: true }, {}],
    [{ state: "sending", sentAt: now - 30_000, queued: true }, {}],
    [{ state: "sending", sentAt: now, waitingForHost: true }, {}],
    [{ state: "delivered", acceptedAt: now }, {}],
    [{ state: "read", acceptedAt: now, readAt: now }, {}],
    [
      { state: "failed", code: "timeout", failedAt: now },
      { failed: true, pending: false, error: "Not sent" },
    ],
  ];
  for (const [delivery, extra] of states) {
    const container = await render(prompt(delivery, extra));
    const state = said(container);
    expect(state.stillSending, JSON.stringify(delivery)).toBe(false);
    expect(state.age > 0 && state.pending > 0, JSON.stringify(delivery)).toBe(false);
    expect(state.pending, JSON.stringify(delivery)).toBeLessThanOrEqual(1);
    await act(async () => root!.unmount());
    root = undefined;
    dom?.window.close();
  }
});
