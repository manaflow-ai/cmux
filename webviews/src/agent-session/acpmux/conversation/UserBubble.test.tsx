import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import type { ComposerAttachment } from "../attachments";
import { translate } from "../i18n";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { UserBubble } from "./UserBubble";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
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
    saved.set(key, scope[key]);
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
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(row: AcpmuxRow, actions: TurnActions = {}): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <UserBubble row={row} text="" />
      </TurnActionsContext.Provider>,
    );
  });
  return container;
}

const image = { id: "image-1", mimeType: "image/png", name: "screenshot.png" };
const baseRow = (): AcpmuxRow => ({
  id: "user-1",
  version: 1,
  kind: "user",
  at: Date.now() - 10_000,
  images: [image],
});

test("an image-only prompt keeps slow delivery feedback without an empty bubble", async () => {
  const row: AcpmuxRow = {
    ...baseRow(),
    delivery: {
      state: "sending",
      slow: true,
      promptId: "prompt-1",
      sessionId: "session-1",
      sentAt: Date.now() - 10_000,
    },
  };
  const container = await render(row);

  expect(container.querySelector(".cv-user__bubble")).toBeNull();
  expect(container.querySelector(".cv-user__bubble-wrap.is-empty")).not.toBeNull();
  expect(container.querySelector(".cv-user__delivery")?.getAttribute("aria-label")).toBe(
    translate("prompt.delivery.stillSending"),
  );
  expect(container.querySelector(".cv-user__actions")).not.toBeNull();
  expect(container.querySelector(`button[aria-label="${translate("turn.retry")}"]`)).toBeNull();
});

test("a delivered image-only prompt exposes retry, fork, and version actions", async () => {
  const row = baseRow();
  const actions: TurnActions = {
    retry: () => {},
    fork: () => {},
    forkSeq: 7,
    promptTurns: new Map([[row.id, 7]]),
    branches: {
      of: new Map([[row.id, { index: 0, sessions: ["session-1", "session-2"] }]]),
      open: () => {},
    },
  };
  const container = await render(row, actions);

  expect(container.querySelector(".cv-user__bubble")).toBeNull();
  expect(container.querySelector(".cv-user__actions")).not.toBeNull();
  for (const label of [
    "turn.copy",
    "turn.retry",
    "turn.fork",
    "message.previousVersion",
    "message.nextVersion",
  ] as const)
    expect(container.querySelector(`button[aria-label="${translate(label)}"]`)).not.toBeNull();
});

test("an inline attachment-only prompt keeps its media strip and footer", async () => {
  const row: AcpmuxRow = {
    ...baseRow(),
    images: undefined,
    inlineParts: [{ kind: "file", name: "notes.txt", mimeType: "text/plain", size: 12 }],
  };
  const container = await render(row, { retry: () => {} });

  expect(container.querySelector(".cv-user__inline-strip")).not.toBeNull();
  expect(container.querySelector(".cv-user__inline-file")).not.toBeNull();
  expect(container.querySelector(".cv-user__actions")).not.toBeNull();
});

test("an image-only prompt still hides retry while its send is pending", async () => {
  const row: AcpmuxRow = {
    ...baseRow(),
    pending: true,
    delivery: {
      state: "sending",
      promptId: "prompt-1",
      sessionId: "session-1",
      sentAt: Date.now() - 10_000,
    },
  };
  const container = await render(row, { retry: () => {} });

  expect(container.querySelector(".cv-user__delivery")).not.toBeNull();
  expect(container.querySelector(`button[aria-label="${translate("turn.retry")}"]`)).toBeNull();
});

for (const kind of ["image", "document", "audio", "text", "pasted", "link"] as const) {
  test(`a ${kind} attachment retained for retry keeps its footer and retries the source row`, async () => {
    const attachment: ComposerAttachment = {
      id: "attachment",
      kind,
      name: "attachment",
      mimeType: "text/plain",
      size: 1,
    };
    const row: AcpmuxRow = { ...baseRow(), images: undefined, retryAttachments: [attachment] };
    const retried: string[] = [];
    const container = await render(row, {
      retry: (id) => {
        retried.push(id);
      },
    });
    expect(container.querySelector(".cv-user__actions")).not.toBeNull();
    const retry = container.querySelector<HTMLButtonElement>(`button[aria-label="${translate("turn.retry")}"]`);
    expect(retry).not.toBeNull();
    await act(async () => retry!.click());
    expect(retried).toEqual([row.id]);
  });
}
