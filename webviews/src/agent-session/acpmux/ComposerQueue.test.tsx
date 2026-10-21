// A queued prompt's row shows its actions (Leo, 2026-10-20: "where the hell is the edit button?"):
// Edit, Remove and Send now, each a button named by its tooltip, and each does what it says through
// `_acpmux/queue_edit` or the withdraw. Send now is a click only: no key sends it.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ComposerQueue } from "./ComposerQueue";
import type { QueueEdit } from "./model";

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

const t = (key: string) => key;
const queue = [
  { id: "p-1", prompt: "first" },
  { id: "p-2", prompt: "second" },
];

async function render(
  onChange: (id: string, edit: QueueEdit) => Promise<boolean>,
  onRemove: (id: string) => Promise<boolean>,
) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<ComposerQueue queue={queue} chat="c" t={t} onChange={onChange} onRemove={onRemove} />);
  });
  return container;
}

function actions(container: HTMLElement, id: string) {
  const row = container.querySelector(`[data-prompt-id="${id}"]`)!;
  return [...row.querySelectorAll<HTMLButtonElement>(".acpmux-queued-action")];
}

test("every queued row shows Edit, Remove and Send now, each with its tooltip", async () => {
  const container = await render(
    async () => true,
    async () => true,
  );
  for (const entry of queue) {
    const buttons = actions(container, entry.id);
    expect(buttons.map((b) => b.dataset.action)).toEqual(["edit", "remove", "send"]);
    expect(buttons.map((b) => b.title)).toEqual([
      "composer.queueEdit",
      "composer.queueRemove",
      "composer.queueSendNow",
    ]);
    for (const b of buttons) expect(b.getAttribute("aria-label")).toBe(b.title);
  }
});

test("Send now sends the prompt now, Remove withdraws it", async () => {
  const edits: [string, QueueEdit][] = [];
  const removed: string[] = [];
  const container = await render(
    async (id, edit) => {
      edits.push([id, edit]);
      return true;
    },
    async (id) => {
      removed.push(id);
      return true;
    },
  );
  const [, , send] = actions(container, "p-2");
  await act(async () => send.click());
  const [, remove] = actions(container, "p-1");
  await act(async () => remove.click());
  expect(edits).toEqual([["p-2", { op: "send_now" }]]);
  expect(removed).toEqual(["p-1"]);
});

test("Edit opens the prompt's text in its row", async () => {
  const container = await render(
    async () => true,
    async () => true,
  );
  const [edit] = actions(container, "p-1");
  await act(async () => edit.click());
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea');
  expect(field?.value).toBe("first");
});

test("⌘↩ on a row, held or not, sends nothing and keeps focus on it", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await render(
    async (id, edit) => {
      edits.push([id, edit]);
      return true;
    },
    async () => true,
  );
  const row = container.querySelector<HTMLElement>('[data-prompt-id="p-1"]')!;
  row.focus();
  const press = (repeat: boolean) =>
    row.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", metaKey: true, repeat, bubbles: true }));
  await act(async () => {
    press(false);
    press(true);
    press(true);
  });
  expect(edits).toEqual([]);
  expect(dom!.window.document.activeElement).toBe(row);
});

// A queued prompt keeps and shows its images (Leo, 2026-10-21: "do queued messages have pics?"):
// small thumbnails under its text, each opening the image viewer; while it is edited, each has a
// remove control, and saving keeps only the images left.
const SHOT_A = "a".repeat(64);
const SHOT_B = "b".repeat(64);
const pictured = [
  {
    id: "p-1",
    prompt: "why does this overlap?",
    images: [
      { id: SHOT_A, mimeType: "image/png", name: "sidebar.png", src: "data:image/png;base64,QQ==" },
      { id: SHOT_B, mimeType: "image/png", name: "toolbar.png", src: "data:image/png;base64,Qg==" },
    ],
  },
];

async function renderPictured(onChange: (id: string, edit: QueueEdit) => Promise<boolean>, opened: string[][]) {
  const container = installDom();
  const { ImageViewerContext } = await import("./conversation/imageViewerContext");
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ImageViewerContext.Provider value={(src, alt) => opened.push([src, alt])}>
        <ComposerQueue queue={pictured} chat="c" t={t} onChange={onChange} onRemove={async () => true} />
      </ImageViewerContext.Provider>,
    );
  });
  return container;
}

const thumbnails = (container: HTMLElement) => [
  ...container.querySelectorAll<HTMLButtonElement>('[data-prompt-id="p-1"] .acpmux-queued-image'),
];

test("a queued prompt with two images shows two thumbnails under its text; a click opens one", async () => {
  const opened: string[][] = [];
  const container = await renderPictured(async () => true, opened);
  const shown = thumbnails(container);
  expect(shown.length).toBe(2);
  expect(shown.map((button) => button.querySelector("img")?.getAttribute("src"))).toEqual([
    "data:image/png;base64,QQ==",
    "data:image/png;base64,Qg==",
  ]);
  // Under the text: the thumbnails come after it in the row.
  const text = container.querySelector('[data-prompt-id="p-1"] .acpmux-queued-text')!;
  expect(text.compareDocumentPosition(shown[0]!) & dom!.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  await act(async () => shown[1]!.click());
  expect(opened).toEqual([["data:image/png;base64,Qg==", "toolbar.png"]]);
});

test("editing a queued prompt removes one of its images and saves the rest", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await renderPictured(async (id, edit) => {
    edits.push([id, edit]);
    return true;
  }, []);
  const [edit] = actions(container, "p-1");
  await act(async () => edit.click());
  const removes = [
    ...container.querySelectorAll<HTMLButtonElement>('[data-prompt-id="p-1"] .acpmux-queued-image-remove'),
  ];
  expect(removes.length).toBe(2);
  await act(async () => removes[0]!.click());
  expect(thumbnails(container).length).toBe(1);
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
  await act(async () => {
    field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(edits).toEqual([["p-1", { op: "update", text: "why does this overlap?", images: [SHOT_B] }]]);
});

test("from the keyboard, Tab reaches an image's remove control without ending the edit", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await renderPictured(async (id, edit) => {
    edits.push([id, edit]);
    return true;
  }, []);
  const [edit] = actions(container, "p-1");
  await act(async () => edit.click());
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
  const [remove] = container.querySelectorAll<HTMLButtonElement>('[data-prompt-id="p-1"] .acpmux-queued-image-remove');
  // Tab from the field to the first image's remove control: the edit stays open.
  await act(async () => remove!.focus());
  expect(edits).toEqual([]);
  expect(field.isConnected).toBe(true);
  // Return on it removes the image and hands focus back to the field, where Return saves.
  await act(async () => remove!.click());
  expect(thumbnails(container).length).toBe(1);
  expect(dom!.window.document.activeElement).toBe(field);
  await act(async () => {
    field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(edits).toEqual([["p-1", { op: "update", text: "why does this overlap?", images: [SHOT_B] }]]);
});

test("focus leaving an image's remove control for outside the row saves the edit", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await renderPictured(async (id, edit) => {
    edits.push([id, edit]);
    return true;
  }, []);
  const [edit] = actions(container, "p-1");
  await act(async () => edit.click());
  const [first, second] = container.querySelectorAll<HTMLButtonElement>(
    '[data-prompt-id="p-1"] .acpmux-queued-image-remove',
  );
  await act(async () => first!.focus());
  // To the next image's control: still editing.
  await act(async () => second!.focus());
  expect(edits).toEqual([]);
  await act(async () => second!.click());
  const outside = dom!.window.document.createElement("button");
  dom!.window.document.body.append(outside);
  await act(async () => first!.focus());
  await act(async () => outside.focus());
  expect(edits).toEqual([["p-1", { op: "update", text: "why does this overlap?", images: [SHOT_A] }]]);
});

test("focus moving from an image's remove control to its row saves the edit", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await renderPictured(async (id, edit) => {
    edits.push([id, edit]);
    return true;
  }, []);
  const [edit] = actions(container, "p-1");
  await act(async () => edit.click());
  const row = container.querySelector<HTMLElement>('[data-prompt-id="p-1"]')!;
  const [remove] = container.querySelectorAll<HTMLButtonElement>('[data-prompt-id="p-1"] .acpmux-queued-image-remove');
  await act(async () => remove!.focus());
  await act(async () => row.focus());
  expect(edits).toEqual([]);
  expect(container.querySelector('[data-prompt-id="p-1"] textarea')).toBeNull();
});

test("editing only a queued prompt's text sends no image list, so it keeps them all", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await renderPictured(async (id, edit) => {
    edits.push([id, edit]);
    return true;
  }, []);
  const [edit] = actions(container, "p-1");
  await act(async () => edit.click());
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
  await act(async () => {
    field.value = "why does the sidebar overlap?";
    field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(edits).toEqual([["p-1", { op: "update", text: "why does the sidebar overlap?" }]]);
});
