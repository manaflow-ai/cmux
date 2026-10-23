// A queued prompt's row shows ChatGPT's and Codex's actions, in their order (Leo, 2026-10-21: "I
// thought we had a trash can"): Steer (its text beside its glyph), a trash can that deletes it, and
// a ⋯ menu with Edit message and Turn off queueing. Steer sends the prompt now through
// `_acpmux/queue_edit` send_now; Delete withdraws it. Steer is a click only: no key sends it.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ComposerQueue } from "./ComposerQueue";
import { queuedRowsState } from "./queuedRowsState";
import type { QueueEdit } from "./model";
import { queueingOn, setQueueing } from "./queueing";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  // The ⋯ menu (ui/Menu, Base UI) places its popup on the next frame.
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  setQueueing(true);
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

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

/** A menu item's label, without the key it names (Edit message's ↩). */
const itemLabel = (item: Element) =>
  [...item.childNodes]
    .filter((node) => !(node instanceof dom!.window.Element && node.classList.contains("ui-menu-shortcut")))
    .map((node) => node.textContent)
    .join("")
    .trim();

/** Opens a row's ⋯ menu; resolves with its items' labels. */
async function openMore(container: HTMLElement, id: string) {
  const more = actions(container, id).find((button) => button.dataset.menu === "queued-more")!;
  await act(async () => more.click());
  await settle();
  return [...dom!.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].map(itemLabel);
}

function menuItem(label: string) {
  return [...dom!.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => itemLabel(item) === label,
  )!;
}

/** Return on a row edits it in place, as the ⋯ menu's Edit message does. */
async function startEdit(container: HTMLElement, id: string) {
  const row = container.querySelector<HTMLElement>(`[data-prompt-id="${id}"]`)!;
  row.focus();
  await act(async () => {
    row.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
}

test("every queued row shows Steer, Delete and More, in that order, each named", async () => {
  const container = await render(
    async () => true,
    async () => true,
  );
  for (const entry of queue) {
    const buttons = actions(container, entry.id);
    expect(buttons.map((b) => b.dataset.action ?? b.dataset.menu)).toEqual(["steer", "delete", "queued-more"]);
    expect(buttons.map((b) => b.getAttribute("aria-label"))).toEqual([
      "composer.queueSteer",
      "composer.queueDelete",
      "composer.queueActions",
    ]);
    // Steer is a text button: its word shows beside its glyph. Delete is the trash can.
    expect(buttons[0]!.textContent?.trim()).toBe("composer.queueSteer");
    expect(buttons[1]!.querySelector("svg")?.dataset.icon).toBe("action.delete");
    expect(buttons[1]!.title).toBe("composer.queueDelete");
  }
});

test("Steer sends the prompt now through the queue's steer path; Delete withdraws it", async () => {
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
  const [steer] = actions(container, "p-2");
  await act(async () => steer!.click());
  const [, remove] = actions(container, "p-1");
  await act(async () => remove!.click());
  expect(edits).toEqual([["p-2", { op: "send_now" }]]);
  expect(removed).toEqual(["p-1"]);
  expect(container.querySelector('[data-prompt-id="p-1"]')).toBeNull();
});

test("the ⋯ menu holds Edit message and Turn off queueing; Edit message opens the text in its row", async () => {
  const container = await render(
    async () => true,
    async () => true,
  );
  expect(await openMore(container, "p-1")).toEqual(["composer.queueEditMessage", "composer.queueingOff"]);
  await act(async () => menuItem("composer.queueEditMessage").click());
  await settle();
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea');
  expect(field?.value).toBe("first");
});

test("Turn off queueing turns queueing off, and the menu then offers to turn it back on", async () => {
  const container = await render(
    async () => true,
    async () => true,
  );
  expect(queueingOn()).toBe(true);
  await openMore(container, "p-1");
  await act(async () => menuItem("composer.queueingOff").click());
  await settle();
  expect(queueingOn()).toBe(false);
  expect(await openMore(container, "p-1")).toEqual(["composer.queueEditMessage", "composer.queueingOn"]);
});

test("where the chat opens side chats, the ⋯ menu's Open in side chat asks the prompt there and withdraws it", async () => {
  const container = installDom();
  const asked: [string, string][] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={queue}
        chat="c"
        t={t}
        onChange={async () => true}
        onRemove={async () => true}
        onSideChat={async (id, prompt) => {
          asked.push([id, prompt]);
          return true;
        }}
      />,
    );
  });
  expect(await openMore(container, "p-2")).toEqual([
    "composer.queueEditMessage",
    "composer.queueSideChat",
    "composer.queueingOff",
  ]);
  await act(async () => menuItem("composer.queueSideChat").click());
  await settle();
  expect(asked).toEqual([["p-2", "second"]]);
  expect(container.querySelector('[data-prompt-id="p-2"]')).toBeNull();
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
  await startEdit(container, "p-1");
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

test("focus moving from the edit's field to an image's remove control keeps the edit open", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await renderPictured(async (id, edit) => {
    edits.push([id, edit]);
    return true;
  }, []);
  await startEdit(container, "p-1");
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
  const [remove] = container.querySelectorAll<HTMLButtonElement>('[data-prompt-id="p-1"] .acpmux-queued-image-remove');
  // Focus moves from the field to the first image's remove control (Tab, in a browser): the
  // edit stays open.
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
  await startEdit(container, "p-1");
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
  await startEdit(container, "p-1");
  const row = container.querySelector<HTMLElement>('[data-prompt-id="p-1"]')!;
  const [remove, second] = container.querySelectorAll<HTMLButtonElement>(
    '[data-prompt-id="p-1"] .acpmux-queued-image-remove',
  );
  // The second image goes (a click, so the field keeps focus); then focus is on the first's control.
  await act(async () => second!.click());
  await act(async () => remove!.focus());
  expect(edits).toEqual([]);
  await act(async () => row.focus());
  expect(edits).toEqual([["p-1", { op: "update", text: "why does this overlap?", images: [SHOT_A] }]]);
  expect(container.querySelector('[data-prompt-id="p-1"] textarea')).toBeNull();
});

test("Esc on an image's remove control cancels the edit and keeps every image", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await renderPictured(async (id, edit) => {
    edits.push([id, edit]);
    return true;
  }, []);
  await startEdit(container, "p-1");
  const [remove, second] = container.querySelectorAll<HTMLButtonElement>(
    '[data-prompt-id="p-1"] .acpmux-queued-image-remove',
  );
  await act(async () => second!.click());
  expect(thumbnails(container).length).toBe(1);
  await act(async () => remove!.focus());
  await act(async () => {
    remove!.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(edits).toEqual([]);
  expect(container.querySelector('[data-prompt-id="p-1"] textarea')).toBeNull();
  expect(thumbnails(container).length).toBe(2);
  expect(dom!.window.document.activeElement).toBe(container.querySelector('[data-prompt-id="p-1"]'));
});

test("editing only a queued prompt's text sends no image list, so it keeps them all", async () => {
  const edits: [string, QueueEdit][] = [];
  const container = await renderPictured(async (id, edit) => {
    edits.push([id, edit]);
    return true;
  }, []);
  await startEdit(container, "p-1");
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
  await act(async () => {
    field.value = "why does the sidebar overlap?";
    field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(edits).toEqual([["p-1", { op: "update", text: "why does the sidebar overlap?" }]]);
});

test("chat_state reads each queued row's text, its image ids and how far each thumbnail got", async () => {
  const container = await renderPictured(async () => true, []);
  const [first, second] = thumbnails(container).map((button) => button.querySelector("img")!);
  expect(queuedRowsState(container)).toEqual([
    {
      promptId: "p-1",
      text: "why does this overlap?",
      editing: false,
      images: [
        { id: SHOT_A, label: "sidebar.png", thumbnail: "loading" },
        { id: SHOT_B, label: "toolbar.png", thumbnail: "loading" },
      ],
    },
  ]);
  // One draws, the other's bytes do not.
  await act(async () => {
    first!.dispatchEvent(new dom!.window.Event("load"));
    second!.dispatchEvent(new dom!.window.Event("error"));
  });
  expect(queuedRowsState(container)[0]!.images.map((image) => image.thumbnail)).toEqual(["loaded", "failed"]);
  // In edit mode the row reads the field's text.
  await startEdit(container, "p-1");
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
  field.value = "why does the toolbar overlap?";
  expect(queuedRowsState(container)[0]).toMatchObject({ editing: true, text: "why does the toolbar overlap?" });
});

test("a queued image acpmux has no bytes for reads as missing, one being read as reading", async () => {
  const container = installDom();
  let finish: (url: string | undefined) => void = () => undefined;
  const queue = [{ id: "p-2", prompt: "see", images: [{ id: SHOT_A, mimeType: "image/png", name: "shot.png" }] }];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={queue}
        chat="c"
        t={t}
        readImage={() => new Promise<string | undefined>((resolve) => (finish = resolve))}
      />,
    );
  });
  expect(queuedRowsState(container)[0]!.images).toEqual([{ id: SHOT_A, label: "shot.png", thumbnail: "reading" }]);
  await act(async () => finish(undefined));
  expect(queuedRowsState(container)[0]!.images).toEqual([{ id: SHOT_A, label: "shot.png", thumbnail: "missing" }]);
});
