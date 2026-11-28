// Failed sends (Leo 2026-10-21): every failed message had its own Retry, Edit, Remove and Details
// row. Leo, 2026-11-24, on the "Not sent" card and its four links: "these 4 buttons are really bad
// tho. i dont ever want to see these, it should just fix itself automtically. recovery for this
// stuff is wack". A send that did not get there for a reason that passes draws no card (its row stays
// the pending row and goes again by itself); a refusal that would come back the same says why in one
// line under the last prompt of its run, with Trust folder where that fixes it, and no links.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxRow, AcpmuxSnapshot, PromptDelivery } from "../model";
import type { ComposerAttachment } from "../attachments";
import { failedRuns, failedSendText } from "../sendFailure";
import { messageMenuTarget } from "./messageMenu";
import { DeliveryFailure } from "./PromptDelivery";
import { FailedSendsContext, type FailedSends } from "./promptDeliveryModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
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

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const failed = (id: string, text: string, delivery: Partial<PromptDelivery>): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind: "user",
  text,
  failed: true,
  error: delivery.reason === "trust.pending" ? translate("prompt.failure.trustPending") : "Not sent: no answer.",
  delivery: { state: "failed", promptId: id, sessionId: "s", sentAt: 0, failedAt: 10, hop: "acpmux", ...delivery },
});
const trustPending = {
  reason: "trust.pending",
  error: "trust.pending: answer the trust question for the folder first",
};

/// The transcript's failed prompts as App.tsx draws them: each row's DeliveryFailure under the chat's context.
function transcript(rows: AcpmuxRow[], sends: Omit<FailedSends, "runs">) {
  const context: FailedSends = { ...sends, runs: failedRuns(rows) };
  return (
    <FailedSendsContext.Provider value={context}>
      {rows.map((row) => (
        <div key={row.id} data-row={row.id}>
          <DeliveryFailure row={row} />
        </div>
      ))}
    </FailedSendsContext.Provider>
  );
}

const button = (container: HTMLElement, name: string) =>
  [...container.querySelectorAll("button")].find((node) => node.textContent === name) as HTMLButtonElement | undefined;

const linkNames = ["Retry", "Edit", "Remove", "Details"];

test("a refusal that would come back the same says one line under its run, with no Retry, Edit, Remove or Details", async () => {
  const rows = [
    failed("a", "ship it", trustPending),
    failed("b", "and the tests", trustPending),
    failed("c", "open a PR", trustPending),
    // Another refusal starts its own line.
    failed("d", "deploy", { code: "-32000", reason: "agent.refused", error: "the agent refused this prompt" }),
  ];
  const container = await render(transcript(rows, {}));
  const cards = container.querySelectorAll(".cv-user__status--failed");
  expect(cards).toHaveLength(2);
  // The run's line sits under its last prompt; the others draw none.
  expect(container.querySelector('[data-row="a"] .cv-user__status--failed')).toBeNull();
  expect(container.querySelector('[data-row="b"] .cv-user__status--failed')).toBeNull();
  expect(container.querySelector('[data-row="c"] .cv-user__status--failed')).not.toBeNull();
  for (const card of cards) {
    expect(card.querySelectorAll(".cv-user__failure-text")).toHaveLength(1);
    for (const name of linkNames) expect(button(card as HTMLElement, name)).toBeUndefined();
  }
  expect(container.querySelector(".cv-user__delivery-details")).toBeNull();
});

test("a refused run's one control is the pending row's X, which takes the whole run back into the composer", async () => {
  const calls: { name: string; rowIds: unknown }[] = [];
  const rows = [
    failed("a", "ship it", { reason: "agent.refused" }),
    failed("b", "and the tests", { reason: "agent.refused" }),
  ];
  const container = await render(transcript(rows, {}));
  // The page's window, which the row reads its actions from when clicked.
  const scope = (globalThis as { window?: unknown }).window as {
    cmuxAcpmuxActions?: Record<string, (args: { rowIds: unknown }) => void>;
  };
  const before = scope.cmuxAcpmuxActions;
  scope.cmuxAcpmuxActions = {
    "chat.editFailedPrompt": ({ rowIds }) => calls.push({ name: "chat.editFailedPrompt", rowIds }),
  };
  try {
    const card = container.querySelector('[data-row="b"] .cv-user__status--failed') as HTMLElement;
    const buttons = [...card.querySelectorAll("button")];
    expect(buttons.map((each) => each.getAttribute("aria-label"))).toEqual([translate("composer.queueEditMessage")]);
    buttons[0]!.click();
    expect(calls).toEqual([{ name: "chat.editFailedPrompt", rowIds: ["a", "b"] }]);
  } finally {
    scope.cmuxAcpmuxActions = before;
  }
});

test("a send that did not get there for a reason that passes draws no failure line at all", async () => {
  const rows = [
    failed("a", "deploy", { code: "timeout", error: "no answer" }),
    failed("b", "ship", { code: "native.not_connected", error: "not connected" }),
    failed("c", "tests", { code: "transport.closed", error: "WebSocket is not open: readyState 3 (CLOSED)" }),
    failed("d", "lint", { code: "-32000", reason: "provider.overloaded", error: "overloaded" }),
  ];
  const container = await render(transcript(rows, {}));
  expect(container.querySelector(".cv-user__status--failed")).toBeNull();
  expect(container.textContent).not.toContain("Not sent");
  for (const name of linkNames) expect(button(container, name)).toBeUndefined();
});

test("a trust refusal says one plain sentence with Trust folder, and never its raw code", async () => {
  let trusted = 0;
  const container = await render(
    transcript([failed("a", "ship it", trustPending)], {
      trustBlock: "trust.answerFirst",
      trustFolder: () => (trusted += 1),
    }),
  );
  const card = container.querySelector<HTMLElement>(".cv-user__status--failed")!;
  expect(card.querySelector(".cv-user__failure-text")!.textContent).toBe("Not sent until you trust this folder.");
  expect(card.textContent).not.toContain("trust.pending");
  await act(async () => button(card, "Trust folder")!.click());
  expect(trusted).toBe(1);
  for (const name of linkNames) expect(button(card, name)).toBeUndefined();
});

/// A prompt past one message (`message.too_large`, acpmux's `rpc::MAX_MESSAGE_BYTES`) is refused the
/// same way at every Retry (Leo, 2026-10-31: "this is completely hardlocked bc of message size"): its
/// line names the attachment to take out, and its message menu offers no Retry.
test("a prompt too large to send names its largest attachment in one line, and its menu offers no Retry", async () => {
  const tooLarge = { code: -32000, reason: "message.too_large", message: "message too large to send: 16907300 bytes" };
  const attachment = (id: string, name: string, bytes: number): ComposerAttachment => ({
    id,
    kind: "image",
    name,
    mimeType: "image/png",
    size: bytes,
    data: "A".repeat(bytes),
  });
  const attachments = [
    attachment("a", "small.png", 10),
    attachment("b", "screen-recording.png", 4_000),
    attachment("c", "notes.png", 20),
  ];
  const sentence = failedSendText(tooLarge, false, attachments);
  expect(sentence).toBe(translate("prompt.failure.tooLargeFile", { name: "screen-recording.png" }));
  expect(sentence).toContain("screen-recording.png");
  expect(sentence).not.toContain("16907300");
  // With no attachment to name (a long pasted text), it still says how to send it.
  expect(failedSendText(tooLarge, false)).toBe(translate("prompt.failure.tooLarge"));

  const row: AcpmuxRow = {
    ...failed("a", "look at these", { reason: "message.too_large", code: "-32000", error: tooLarge.message }),
    error: sentence,
  };
  const container = await render(transcript([row], {}));
  const card = container.querySelector<HTMLElement>(".cv-user__status--failed")!;
  expect(card.dataset.failureCause).toBe("too-large");
  expect(card.querySelector(".cv-user__failure-text")!.textContent).toBe(sentence);
  for (const name of linkNames) expect(button(card, name)).toBeUndefined();
  // Nor from the message's menu (the native context menu offers Retry for `retryRowId`).
  const other = failed("b", "deploy", { code: "timeout", error: "no answer" });
  const snapshot = { rows: [row, other], connection: "connected" } as unknown as AcpmuxSnapshot;
  expect(messageMenuTarget(snapshot, "a")?.retryRowId).toBeUndefined();
  expect(messageMenuTarget(snapshot, "b")?.retryRowId).toBe("b");
});
