// A sent prompt's row says one thing about its delivery at a time (Leo, 2026-11-11: "what's up with
// this still sending thing? What's the point of that? But, like, it already, like, shows that it's
// sent. So this is incongruous."). Leo, 2026-11-24, on a waiting prompt drawn two ways, the queued
// row with Send now and a "(clock) Sending" in another's footer: "this "sending" is bad" and "this one
// is good. why were ther e2 of them". Now a prompt on its way past its first second, queued, or
// going again by itself draws the queued row (PendingSteer.tsx) in place of its footer; once it
// landed, its footer with its age. A refusal that would come back the same draws no footer, only
// its one line.
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
import { PendingSteer } from "./PendingSteer";

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
        <TurnActionsContext.Provider value={{ retry: () => {}, unsteer: async () => "back" }}>
          {/* As MessageRow draws it: the pending row in place of the footer while it waits. */}
          <UserBubble
            row={row}
            text={row.text ?? ""}
            pending={(actions, queued) => (
              <PendingSteer row={row} send={async () => true} queued={queued}>
                {actions}
              </PendingSteer>
            )}
          />
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

/// What the row says about its delivery: its age (sent), its pending row and its state, the words.
function said(container: HTMLElement) {
  const text = container.textContent ?? "";
  return {
    age: container.querySelectorAll("time.cv-user__time").length,
    pending: container.querySelectorAll(".cv-user__pending").length,
    pendingState: container.querySelector<HTMLElement>(".cv-user__send-now")?.dataset.pendingState,
    clock: container.querySelectorAll(".cv-user__pending-state").length,
    links: [...container.querySelectorAll("button")]
      .map((button) => button.textContent)
      .filter((name) => ["Retry", "Edit", "Remove", "Details"].includes(name ?? "")),
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

test("a slow acknowledgement draws the queued row's look in place of its footer, and no clock", async () => {
  const container = await render(prompt({ state: "sending", sentAt: Date.now() - 15_000, slow: true }));
  const state = said(container);
  expect(state.pending).toBe(1);
  expect(state.pendingState).toBe("sending");
  expect(state.clock).toBe(0);
  expect(state.age).toBe(0);
  expect(state.stillSending).toBe(false);
  expect(state.notSentYet).toBe(false);
  expect(container.textContent).not.toContain(translate("prompt.delivery.sending"));
});

// Leo, 2026-11-17: "Queued, sends when the turn ends" / "it's not really useful to see ever". A
// prompt waiting behind the running turn keeps its time in the slot: no clock, no queued words.
test("a prompt queued behind the running turn never says Queued in its footer: its slot keeps its age", async () => {
  const container = await render(prompt({ state: "sending", sentAt: Date.now() - 5_000, queued: true }));
  const state = said(container);
  expect(state.pending).toBe(0);
  expect(state.clock).toBe(0);
  expect(state.age).toBe(1);
  expect(container.textContent).not.toContain("Queued, sends when");
  expect(container.querySelector("[aria-label^='Queued']")).toBeNull();
  expect(state.notSentYet).toBe(false);
});

test("a send held while the agent service reconnects says nothing in its first second, then the same row", async () => {
  const now = await render(prompt({ state: "sending", sentAt: Date.now(), waitingForHost: true }));
  expect(said(now).clock).toBe(0);
  expect(said(now).pending).toBe(0);
  await act(async () => root!.unmount());
  root = undefined;
  const later = await render(prompt({ state: "sending", sentAt: Date.now() - 5_000, waitingForHost: true }));
  expect(said(later).pendingState).toBe("sending");
  expect(said(later).clock).toBe(0);
});

// Leo, 2026-11-24: "these 4 buttons are really bad tho. i dont ever want to see these, it should just
// fix itself automtically". A send the link lost keeps its pending row and goes again by itself.
test("a send the link lost keeps the same pending row, with no Not sent and no links", async () => {
  for (const code of ["native.timed_out", "native.not_connected", "timeout", "transport.closed"]) {
    const container = await render(
      prompt(
        { state: "failed", code, hop: "connection", failedAt: Date.now() },
        { failed: true, pending: false, error: translate("prompt.failure.hostAway") },
      ),
    );
    const state = said(container);
    expect(state.pendingState, code).toBe("retrying");
    expect(state.links, code).toEqual([]);
    expect(state.notSentYet, code).toBe(false);
    expect(container.querySelector(".cv-user__status--failed"), code).toBeNull();
    await act(async () => root!.unmount());
    root = undefined;
  }
});

test("a refusal that would come back the same says one line, with no links and no sent footer", async () => {
  const container = await render(
    prompt(
      { state: "failed", reason: "message.too_large", failedAt: Date.now() },
      { failed: true, pending: false, error: translate("prompt.failure.tooLarge") },
    ),
  );
  const state = said(container);
  expect(state.pending).toBe(0);
  expect(state.age).toBe(0);
  expect(state.links).toEqual([]);
  expect(container.querySelectorAll(".cv-user__status--failed .cv-user__failure-text")).toHaveLength(1);
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
    expect(state.clock, JSON.stringify(delivery)).toBe(0);
    await act(async () => root!.unmount());
    root = undefined;
    dom?.window.close();
  }
});

// Leo, 2026-11-24 06:32Z: "save prompt butotn still bad". No message footer or pending row offers
// Save as Prompt: a sent prompt's footer, a slow send's pending row and a queued steer's row.
test("no footer or pending row draws Save as Prompt; the queued row reads copy, X and Send now", async () => {
  const labels = (container: HTMLElement) =>
    [...container.querySelectorAll("button")].map((button) => button.getAttribute("aria-label") ?? button.textContent);
  const sent = await render(prompt({ state: "delivered" }));
  expect(labels(sent)).not.toContain("Save as Prompt");
  expect(sent.querySelector(".cv-save-prompt")).toBeNull();
  const slow = await render(prompt({ state: "sending", sentAt: Date.now() - 5_000 }));
  expect(labels(slow)).not.toContain("Save as Prompt");
  const queued = await render(prompt({ state: "delivered" }, { steer: "waiting", steerPromptId: "p-steer-save" }));
  expect(queued.querySelector(".cv-save-prompt")).toBeNull();
  expect(
    [...queued.querySelectorAll(".cv-user__pending button")].map((button) =>
      button.classList.contains("cv-user__send-now")
        ? "send-now"
        : button.classList.contains("cv-user__take-back")
          ? "x"
          : button.getAttribute("aria-label"),
    ),
  ).toEqual([translate("turn.copy"), "x", "send-now"]);
});
