// Failed sends by cause (Leo 2026-10-21): every failed message had its own Retry, Edit, Remove and
// Details row, and a trust failure's Retry could only be refused again. Prompts that failed in a
// row for one cause share one card under the last of them, its actions name every prompt of the
// run, and a trust failure's card offers Trust folder and holds Retry while the folder's
// question is open.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxRow, AcpmuxSnapshot, PromptDelivery } from "../model";
import type { ComposerAttachment } from "../attachments";
import { failedRuns, failedSendText } from "../sendFailure";
import { messageMenuTarget } from "./messageMenu";
import { DeliveryFailure, FailedSendsContext, type FailedSends } from "./PromptDelivery";

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

test("failed prompts in a row with one cause share one card, whose actions name every prompt of the run", async () => {
  const rows = [
    failed("a", "ship it", trustPending),
    failed("b", "and the tests", trustPending),
    failed("c", "open a PR", trustPending),
    // Another cause starts its own card.
    failed("d", "deploy", { code: "timeout", error: "no answer" }),
  ];
  const calls: { name: string; params: Record<string, unknown> }[] = [];
  const container = await render(transcript(rows, {}));
  window.cmuxAcpmuxActions = Object.fromEntries(
    ["chat.retryPrompt", "chat.editFailedPrompt", "chat.removeFailedPrompt"].map((name) => [
      name,
      async (params: Record<string, unknown>) => void calls.push({ name, params }),
    ]),
  );
  const cards = container.querySelectorAll(".cv-user__status--failed");
  expect(cards).toHaveLength(2);
  // The run's card sits under its last prompt; the others draw none.
  expect(container.querySelector('[data-row="a"] .cv-user__status--failed')).toBeNull();
  expect(container.querySelector('[data-row="b"] .cv-user__status--failed')).toBeNull();
  expect(container.querySelector('[data-row="c"] .cv-user__status--failed')).not.toBeNull();
  expect(container.querySelector('[data-row="d"] .cv-user__status--failed')).not.toBeNull();
  expect([...container.querySelectorAll("button")].filter((node) => node.textContent === "Retry")).toHaveLength(2);
  const card = container.querySelector<HTMLElement>('[data-row="c"]')!;
  await act(async () => button(card, "Retry")!.click());
  await act(async () => button(card, "Remove")!.click());
  expect(calls.map((call) => [call.name, call.params.rowIds])).toEqual([
    ["chat.retryPrompt", ["a", "b", "c"]],
    ["chat.removeFailedPrompt", ["a", "b", "c"]],
  ]);
});

test("a trust failure's card says one plain sentence with Trust folder, and its raw code only under Details", async () => {
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
  await act(async () => button(card, "Details")!.click());
  expect(card.querySelector(".cv-user__delivery-details")!.textContent).toContain(
    "trust.pending: answer the trust question for the folder first (trust.pending)",
  );
});

test("Retry waits while the folder's trust question is open, and comes back once it is answered", async () => {
  const rows = [failed("a", "ship it", trustPending)];
  const container = await render(transcript(rows, { trustBlock: "trust.answerFirst", trustFolder: () => undefined }));
  expect(button(container, "Retry")!.disabled).toBe(true);
  expect(button(container, "Retry")!.title).toBe("Answer the trust question first");
  await act(async () => root!.render(transcript(rows, {})));
  expect(button(container, "Retry")!.disabled).toBe(false);
  // Trusted: nothing left to fix.
  expect(button(container, "Trust folder")).toBeUndefined();
  // Any other cause never waits on the trust question.
  await act(async () =>
    root!.render(
      transcript([failed("b", "deploy", { code: "timeout", error: "no answer" })], {
        trustBlock: "trust.answerFirst",
        trustFolder: () => undefined,
      }),
    ),
  );
  expect(button(container, "Retry")!.disabled).toBe(false);
  expect(button(container, "Trust folder")).toBeUndefined();
});

/// A prompt past one message (`message.too_large`, acpmux's `rpc::MAX_MESSAGE_BYTES`) is refused the
/// same way at every Retry (Leo, 2026-10-31: "this is completely hardlocked bc of message size"): its
/// card names the attachment to take out and offers Edit, never Retry.
test("a prompt too large to send names its largest attachment and offers Edit, not Retry", async () => {
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
  expect(button(card, "Retry")).toBeUndefined();
  expect(button(card, "Edit")).toBeDefined();
  // Nor from the message's menu (the native context menu offers Retry for `retryRowId`).
  const other = failed("b", "deploy", { code: "timeout", error: "no answer" });
  const snapshot = { rows: [row, other], connection: "connected" } as unknown as AcpmuxSnapshot;
  expect(messageMenuTarget(snapshot, "a")?.retryRowId).toBeUndefined();
  expect(messageMenuTarget(snapshot, "b")?.retryRowId).toBe("b");
});
