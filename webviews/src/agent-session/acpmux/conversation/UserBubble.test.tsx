import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import type { ComposerAttachment } from "../attachments";
import { translate } from "../i18n";
import { PresentationContext } from "./presentationContextModel";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { PromptActions } from "./MessageActions";
import { settleReact } from "../../../../test/support/domTeardown";

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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

// Rendered in the Messages view, where every sent prompt draws its own Retry; in the transcript the
// chat's one Retry is the last turn's footer's (turns.ts retryPlacement, cmux#34779).
async function render(row: AcpmuxRow, actions: TurnActions = {}): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <PresentationContext.Provider value="messages">
        <TurnActionsContext.Provider value={actions}>
          <UserBubble row={row} text="" />
        </TurnActionsContext.Provider>
      </PresentationContext.Provider>,
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
  // Its one pending state sits in the footer's time slot, not on an empty line of its own.
  expect(container.querySelector(".cv-user__bubble-wrap.is-empty")).toBeNull();
  expect(container.querySelectorAll(".cv-user__pending-state").length).toBe(1);
  expect(container.querySelector(".cv-user__pending-state")?.getAttribute("aria-label")).toBe(
    translate("prompt.delivery.sending"),
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

// Send and replay record an attachment-only prompt in both shapes: its `images` (or retained
// files) and its `inlineParts`. Each attachment draws once, by one path.
const drawnImages = (container: HTMLElement) =>
  container.querySelectorAll(".cv-user__image, .cv-user__image-placeholder, .cv-user__image-failed").length;
const drawnFiles = (container: HTMLElement) => container.querySelectorAll(".acpmux-file-chip").length;

test("an image-only prompt recorded with images and inline parts draws its image once", async () => {
  const sent = { ...image, src: "data:image/png;base64,iVBORw0KGgo=" };
  const row: AcpmuxRow = {
    ...baseRow(),
    images: [sent],
    inlineParts: [{ kind: "image", ...sent }],
  };
  const container = await render(row);

  expect(drawnImages(container)).toBe(1);
  expect(drawnFiles(container)).toBe(0);
});

test("a file-only prompt recorded with retained files and inline parts draws its file once", async () => {
  const file = { name: "notes.pdf", mimeType: "application/pdf", size: 12 };
  const row: AcpmuxRow = {
    ...baseRow(),
    images: undefined,
    retryAttachments: [{ id: "file-1", kind: "link", ...file }],
    inlineParts: [{ kind: "file", ...file }],
  };
  const container = await render(row);

  expect(drawnFiles(container)).toBe(1);
  expect(drawnImages(container)).toBe(0);
});

test("an attachment-only prompt draws a legacy image its inline parts do not record", async () => {
  const sent = { ...image, src: "data:image/png;base64,iVBORw0KGgo=" };
  const row: AcpmuxRow = {
    ...baseRow(),
    images: [sent],
    inlineParts: [{ kind: "file", name: "notes.pdf", mimeType: "application/pdf", size: 12 }],
  };
  const container = await render(row);

  expect(drawnImages(container)).toBe(1);
  expect(drawnFiles(container)).toBe(1);
});

test("the Messages view's prompt actions offer Retry for an attachment-only prompt", async () => {
  const row: AcpmuxRow = {
    ...baseRow(),
    images: undefined,
    retryAttachments: [{ id: "attachment", kind: "image", name: "a.png", mimeType: "image/png", size: 1 }],
  };
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <PresentationContext.Provider value="messages">
        <TurnActionsContext.Provider value={{ retry: () => {} }}>
          <PromptActions row={row} text="" />
        </TurnActionsContext.Provider>
      </PresentationContext.Provider>,
    );
  });
  expect(container.querySelector(`button[aria-label="${translate("turn.retry")}"]`)).not.toBeNull();
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

  expect(container.querySelector(".cv-user__pending-state")).not.toBeNull();
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

// After a reload or reconnect the attachments this page kept are gone: Retry rebuilds them from the
// row's recorded parts, and one it cannot rebuild hides Retry rather than send the prompt without it.
for (const kind of ["document", "audio"] as const) {
  test(`a recorded ${kind}-only prompt with nothing kept to resend offers no retry`, async () => {
    const row: AcpmuxRow = {
      ...baseRow(),
      images: undefined,
      inlineParts: [{ kind, name: `attachment.${kind === "audio" ? "mp3" : "pdf"}`, mimeType: "application/pdf" }],
    };
    const container = await render(row, { retry: () => {} });
    expect(container.querySelector(".cv-user__actions")).not.toBeNull();
    expect(container.querySelector(`button[aria-label="${translate("turn.copy")}"]`)).not.toBeNull();
    expect(container.querySelector(`button[aria-label="${translate("turn.retry")}"]`)).toBeNull();
  });
}

test("a recorded file-only prompt with no path or text offers no retry", async () => {
  const row: AcpmuxRow = {
    ...baseRow(),
    images: undefined,
    inlineParts: [{ kind: "file", name: "notes.txt", mimeType: "text/plain", size: 12 }],
  };
  const container = await render(row, { retry: () => {} });
  expect(container.querySelector(`button[aria-label="${translate("turn.retry")}"]`)).toBeNull();
});

for (const [label, part] of [
  ["linked file", { kind: "file", name: "notes.pdf", mimeType: "application/pdf", uri: "file:///tmp/notes.pdf" }],
  ["inline text file", { kind: "file", name: "notes.txt", mimeType: "text/plain", text: "hello" }],
  ["paste", { kind: "pasted", name: "Pasted text", text: "hello" }],
  ["image", { kind: "image", ...image }],
] as const) {
  test(`a recorded ${label}-only prompt rebuilds its attachment and offers retry`, async () => {
    const row: AcpmuxRow = { ...baseRow(), images: undefined, inlineParts: [part] };
    const retried: string[] = [];
    const container = await render(row, { retry: (id) => void retried.push(id) });
    const retry = container.querySelector<HTMLButtonElement>(`button[aria-label="${translate("turn.retry")}"]`);
    expect(retry).not.toBeNull();
    await act(async () => retry!.click());
    expect(retried).toEqual([row.id]);
  });
}
