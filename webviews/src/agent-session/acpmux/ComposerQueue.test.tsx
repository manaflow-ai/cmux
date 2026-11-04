// A queued prompt's row shows ChatGPT's and Codex's actions, in their order (Leo, 2026-10-21: "I
// thought we had a trash can"): Steer (its text beside its glyph), a trash can that deletes it, and
// a ⋯ menu with Edit message and Turn off queueing. Steer sends the prompt now through
// `_acpmux/queue_edit` send_now; Delete withdraws it. Steer is a click only: no key sends it.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ComposerQueue, shownText } from "./ComposerQueue";
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
  entries: Parameters<typeof ComposerQueue>[0]["queue"] = queue,
) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<ComposerQueue queue={entries} chat="c" t={t} onChange={onChange} onRemove={onRemove} />);
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

test("a successful Steer hides its action before the next queue snapshot", async () => {
  let resolve: ((ok: boolean) => void) | undefined;
  const container = await render(
    () => new Promise<boolean>((done) => (resolve = done)),
    async () => true,
  );
  expect(actions(container, "p-2").map((button) => button.dataset.action ?? button.dataset.menu)).toEqual([
    "steer",
    "delete",
    "queued-more",
  ]);
  await act(async () => {
    actions(container, "p-2")[0]!.click();
  });
  expect(actions(container, "p-2").map((button) => button.dataset.action ?? button.dataset.menu)).toEqual([
    "steer",
    "delete",
    "queued-more",
  ]);
  await act(async () => {
    resolve!(true);
    await Promise.resolve();
  });
  expect(actions(container, "p-2").map((button) => button.dataset.action ?? button.dataset.menu)).toEqual([
    "delete",
    "queued-more",
  ]);
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

test("cancel and edit withdraws a queued prompt and restores its text and images", async () => {
  const restored: [string, string, { id: string; data?: string }[]][] = [];
  const cancelQueue = [
    {
      ...pictured[0]!,
      images: [pictured[0]!.images![0]!, { ...pictured[0]!.images![1]!, src: undefined }],
    },
  ];
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={cancelQueue}
        chat="c"
        t={t}
        onCancelEdit={async (id, text, attachments) => {
          restored.push([id, text, attachments.map(({ id: imageId, data }) => ({ id: imageId, data }))]);
          return true;
        }}
        readImage={async (id) => (id === SHOT_B ? "data:image/png;base64,Qg==" : undefined)}
      />,
    );
  });
  const cancel = container.querySelector<HTMLButtonElement>('[data-prompt-id="p-1"] [data-action="cancel-edit"]');
  expect(cancel?.querySelector("svg")?.dataset.icon).toBe("action.close");
  await act(async () => cancel!.click());
  await settle();
  expect(restored).toEqual([
    [
      "p-1",
      "why does this overlap?",
      [
        { id: SHOT_A, data: "QQ==" },
        { id: SHOT_B, data: "Qg==" },
      ],
    ],
  ]);
  expect(container.querySelector('[data-prompt-id="p-1"]')).toBeNull();
});

test("cancel and edit leaves a prompt queued when one of its images cannot be read back", async () => {
  const restored: string[] = [];
  const unreadable = [
    {
      ...pictured[0]!,
      images: [pictured[0]!.images![0]!, { ...pictured[0]!.images![1]!, src: undefined }],
    },
  ];
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={unreadable}
        chat="c"
        t={t}
        onCancelEdit={async (id) => {
          restored.push(id);
          return true;
        }}
        readImage={async () => undefined}
      />,
    );
  });
  const cancel = container.querySelector<HTMLButtonElement>('[data-prompt-id="p-1"] [data-action="cancel-edit"]');
  await act(async () => cancel!.click());
  await settle();
  expect(restored).toEqual([]);
  expect(container.querySelector('[data-prompt-id="p-1"]')).not.toBeNull();
});

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

// A shared chat: a teammate's queued prompt names them, and only they may change it (acpmux
// refuses another author's edit with `queue.not_author`), so its row has no actions and no keys.
test("a teammate's queued prompt shows their name and offers no action", async () => {
  const edits: [string, QueueEdit][] = [];
  const removed: string[] = [];
  const container = installDom();
  const ana = { id: "tailnet:ana@example.com", name: "Ana" };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={[{ id: "p-ana", prompt: "from ana", author: ana }, ...queue]}
        chat="c"
        t={t}
        onChange={async (id, edit) => {
          edits.push([id, edit]);
          return true;
        }}
        onRemove={async (id) => {
          removed.push(id);
          return true;
        }}
      />,
    );
  });
  const row = container.querySelector<HTMLElement>('[data-prompt-id="p-ana"]')!;
  expect(row.querySelector(".cv-author--inline .cv-author__name")?.textContent).toBe("Ana");
  expect(actions(container, "p-ana")).toEqual([]);
  expect(row.getAttribute("aria-keyshortcuts")).toBeNull();
  row.focus();
  for (const init of [{ key: "Enter" }, { key: "Backspace" }, { key: "ArrowDown", altKey: true }])
    await act(async () => {
      row.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { ...init, bubbles: true }));
    });
  expect(container.querySelector('[data-prompt-id="p-ana"] textarea')).toBeNull();
  expect(edits).toEqual([]);
  expect(removed).toEqual([]);
  // The person's own rows keep their actions.
  expect(actions(container, "p-1").map((b) => b.dataset.action ?? b.dataset.menu)).toEqual([
    "steer",
    "delete",
    "queued-more",
  ]);
});

// Every other path to a queue change stays shut on a teammate's row: its right-click opens no menu
// (so no Steer, Edit, move, side chat or Delete), it has no cancel-and-edit, and a neighbour's move
// never passes it (each row a move passes shifts one place).
test("a teammate's queued prompt has no menu and no neighbour moves it", async () => {
  const edits: [string, QueueEdit][] = [];
  const touched: string[] = [];
  const container = installDom();
  const ana = { id: "tailnet:ana@example.com", name: "Ana" };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={[queue[0]!, { id: "p-ana", prompt: "from ana", author: ana }, queue[1]!]}
        chat="c"
        t={t}
        onChange={async (id, edit) => {
          edits.push([id, edit]);
          return true;
        }}
        onRemove={async (id) => {
          touched.push(`remove ${id}`);
          return true;
        }}
        onSideChat={async (id) => {
          touched.push(`side ${id}`);
          return true;
        }}
        onCancelEdit={async (id) => {
          touched.push(`cancel ${id}`);
          return true;
        }}
      />,
    );
  });
  const row = (id: string) => container.querySelector<HTMLElement>(`[data-prompt-id="${id}"]`)!;
  const menuItems = () => [...dom!.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
  // On the row's menu host, as a right-click on its text lands.
  const rightClick = async (row: HTMLElement) => {
    const target = row.querySelector<HTMLElement>(".acpmux-queued-menu")!;
    let opened = false;
    await act(async () => {
      opened = !target.dispatchEvent(
        new dom!.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 60 }),
      );
    });
    await settle();
    return opened;
  };
  expect(await rightClick(row("p-ana"))).toBe(false);
  expect(menuItems()).toEqual([]);
  expect(row("p-ana").querySelector('[data-action="cancel-edit"]')).toBeNull();
  expect(actions(container, "p-1").some((b) => b.dataset.action === "cancel-edit")).toBe(true);
  // Alt+↓ on the row above Ana's, and Alt+↑ on the row below it, change nothing.
  for (const [id, key] of [
    ["p-1", "ArrowDown"],
    ["p-2", "ArrowUp"],
  ] as const) {
    row(id).focus();
    await act(async () => {
      row(id).dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, altKey: true, bubbles: true }));
    });
  }
  expect(edits).toEqual([]);
  // The own row's menu offers the move only where it passes no teammate.
  expect(await rightClick(row("p-1"))).toBe(true);
  const down = menuItems().find((item) => itemLabel(item) === "composer.queueMoveDown");
  expect(down?.hasAttribute("disabled") || down?.getAttribute("aria-disabled") === "true").toBe(true);
  await act(async () => down!.click());
  await settle();
  expect(edits).toEqual([]);
  expect(touched).toEqual([]);
});

// An edit opened while the row named no author, then the authored record comes in (an attach page
// replayed, a teammate's own edit): the editor closes, nothing is saved to the teammate's prompt,
// and what the person typed goes back to the composer.
test("an open edit closes, unsaved, when the row turns out to be a teammate's", async () => {
  const edits: [string, QueueEdit][] = [];
  const lost: [string, string][] = [];
  const container = installDom();
  const ana = { id: "tailnet:ana@example.com", name: "Ana" };
  const draw = (rows: Array<{ id: string; prompt: string; author?: typeof ana }>) =>
    root!.render(
      <ComposerQueue
        queue={rows}
        chat="c"
        t={t}
        onChange={async (id, edit) => {
          edits.push([id, edit]);
          return true;
        }}
        onRemove={async () => true}
        onLost={(text, id) => lost.push([id, text])}
      />,
    );
  await act(async () => {
    root = createRoot(container);
    draw(queue);
  });
  await startEdit(container, "p-1");
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
  await act(async () => {
    field.value = "first, reworded";
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await act(async () => draw([{ ...queue[0]!, author: ana }, queue[1]!]));
  await settle();
  expect(container.querySelector('[data-prompt-id="p-1"] textarea')).toBeNull();
  expect(lost).toEqual([["p-1", "first, reworded"]]);
  expect(edits).toEqual([]);
  expect(actions(container, "p-1")).toEqual([]);
});

// A Save whose bridge call fails. Before acpmux could have it (not connected, a typed refusal) the row is
// still queued, so the typed text goes back into that row's editor, never to the composer (the prompt would
// show twice). After a timeout or a closed socket the edit may already be applied: nothing is restored and
// the next snapshot shows the truth. Either way nothing is left unhandled.
async function failedSave(error: Record<string, unknown> | "answered-no") {
  const lost: [string, string][] = [];
  const unhandled: unknown[] = [];
  const onUnhandled = (reason: unknown) => unhandled.push(reason);
  process.on("unhandledRejection", onUnhandled);
  const container = installDom();
  const draw = (rows: typeof queue) =>
    root!.render(
      <ComposerQueue
        queue={rows}
        chat="c"
        t={t}
        onChange={() =>
          error === "answered-no" ? Promise.resolve(false) : Promise.reject(Object.assign(new Error("failed"), error))
        }
        onRemove={async () => true}
        onLost={(text, id) => lost.push([id, text])}
      />,
    );
  await act(async () => {
    root = createRoot(container);
    draw(queue);
  });
  await startEdit(container, "p-1");
  const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
  await act(async () => {
    field.value = "first, reworded";
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  // Two macrotask turns: the rejection settles, then Node reports any one nobody handled.
  await settle();
  await settle();
  process.off("unhandledRejection", onUnhandled);
  const editor = () => container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea');
  return { lost, unhandled, editor, redraw: (rows: typeof queue) => act(async () => draw(rows)) };
}

for (const [name, error] of [
  ["not connected", { code: "native.not_connected" }],
  ["refused by the host", { code: "chat.queue.refused" }],
] as const) {
  test(`a save that fails before acpmux has it (${name}) reopens the row's editor with the typed text`, async () => {
    const run = await failedSave(error);
    expect(run.lost).toEqual([]);
    expect(run.editor()?.value).toBe("first, reworded");
    expect(run.unhandled).toEqual([]);
  });
}

test("a reopened editor hands its text back to the composer if the row is gone when the queue next draws", async () => {
  const run = await failedSave({ code: "native.not_connected" });
  expect(run.editor()?.value).toBe("first, reworded");
  await run.redraw([queue[1]!]);
  await settle();
  expect(run.lost).toEqual([["p-1", "first, reworded"]]);
  expect(run.editor()).toBeNull();
});

// Overlapping saves of one row: A is pending, the row is reopened and B is saved, then A fails and B
// succeeds. A's failure is stale (B superseded it), so it must not reopen A's text: the stale editor would
// autosave A over B when clicked away.
test("an older save that fails after a newer save of the same row began does not reopen its text", async () => {
  const calls: { resolve(ok: boolean): void; reject(error: Error): void }[] = [];
  const lost: [string, string][] = [];
  const unhandled: unknown[] = [];
  const onUnhandled = (reason: unknown) => unhandled.push(reason);
  process.on("unhandledRejection", onUnhandled);
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={queue}
        chat="c"
        t={t}
        onChange={() => new Promise<boolean>((resolve, reject) => calls.push({ resolve, reject }))}
        onRemove={async () => true}
        onLost={(text, id) => lost.push([id, text])}
      />,
    );
  });
  const saveAs = async (text: string) => {
    await startEdit(container, "p-1");
    const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
    await act(async () => {
      field.value = text;
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    await act(async () => {
      field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    });
  };
  await saveAs("text A");
  await saveAs("text B");
  expect(calls).toHaveLength(2);
  const editor = () => container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea');
  expect(editor()).toBeNull();
  await act(async () => calls[0]!.reject(Object.assign(new Error("not connected"), { code: "native.not_connected" })));
  await settle();
  await act(async () => calls[1]!.resolve(true));
  await settle();
  await settle();
  process.off("unhandledRejection", onUnhandled);
  expect(editor()).toBeNull();
  expect(lost).toEqual([]);
  expect(unhandled).toEqual([]);
});

// Two rows saved, then both calls fail in one batch (one bridge reconnect): the first reopens its editor
// with its text; the second waits, keeps its text, and reopens when the first editor closes. Neither
// overwrites the other's recovery, and a waiting row that has gone hands its text to the composer.
async function twoFailedSaves() {
  const calls: { reject(error: Error): void }[] = [];
  const lost: [string, string][] = [];
  const unhandled: unknown[] = [];
  const onUnhandled = (reason: unknown) => unhandled.push(reason);
  process.on("unhandledRejection", onUnhandled);
  const container = installDom();
  const draw = (rows: typeof queue) =>
    root!.render(
      <ComposerQueue
        queue={rows}
        chat="c"
        t={t}
        onChange={() => new Promise<boolean>((_, reject) => calls.push({ reject }))}
        onRemove={async () => true}
        onLost={(text, id) => lost.push([id, text])}
      />,
    );
  await act(async () => {
    root = createRoot(container);
    draw(queue);
  });
  const saveAs = async (id: string, text: string) => {
    await startEdit(container, id);
    const field = container.querySelector<HTMLTextAreaElement>(`[data-prompt-id="${id}"] textarea`)!;
    await act(async () => {
      field.value = text;
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    await act(async () => {
      field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    });
  };
  await saveAs("p-1", "one edited");
  await saveAs("p-2", "two edited");
  const notConnected = () => Object.assign(new Error("not connected"), { code: "native.not_connected" });
  await act(async () => {
    calls[0]!.reject(notConnected());
    calls[1]!.reject(notConnected());
  });
  await settle();
  await settle();
  process.off("unhandledRejection", onUnhandled);
  const editor = (id: string) => container.querySelector<HTMLTextAreaElement>(`[data-prompt-id="${id}"] textarea`);
  const escape = (id: string) =>
    act(async () => {
      editor(id)!.dispatchEvent(
        new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
      );
    });
  return { lost, unhandled, editor, escape, redraw: (rows: typeof queue) => act(async () => draw(rows)) };
}

test("two saves that fail in one batch each keep their text: the second reopens when the first editor closes", async () => {
  const run = await twoFailedSaves();
  expect(run.editor("p-1")?.value).toBe("one edited");
  expect(run.editor("p-2")).toBeNull();
  expect(run.lost).toEqual([]);
  await run.escape("p-1");
  await settle();
  expect(run.editor("p-1")).toBeNull();
  expect(run.editor("p-2")?.value).toBe("two edited");
  expect(run.lost).toEqual([]);
  expect(run.unhandled).toEqual([]);
});

test("a waiting recovery whose row is gone when the editor frees hands its text to the composer", async () => {
  const run = await twoFailedSaves();
  await run.redraw([queue[0]!]);
  await run.escape("p-1");
  await settle();
  expect(run.lost).toEqual([["p-2", "two edited"]]);
  expect(run.editor("p-2")).toBeNull();
});

// A Save answered "no" after a newer Save of the same row began is stale: it must not hand its
// superseded text to the composer (the newer save's text is the one that counts).
test("an older save answered no after a newer save began does not hand its text to the composer", async () => {
  const calls: { resolve(ok: boolean): void }[] = [];
  const lost: [string, string][] = [];
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={queue}
        chat="c"
        t={t}
        onChange={() => new Promise<boolean>((resolve) => calls.push({ resolve }))}
        onRemove={async () => true}
        onLost={(text, id) => lost.push([id, text])}
      />,
    );
  });
  const saveAs = async (text: string) => {
    await startEdit(container, "p-1");
    const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
    await act(async () => {
      field.value = text;
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    await act(async () => {
      field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    });
  };
  await saveAs("text A");
  await saveAs("text B");
  await act(async () => calls[0]!.resolve(false));
  await settle();
  expect(lost).toEqual([]);
  await act(async () => calls[1]!.resolve(false));
  await settle();
  expect(lost).toEqual([["p-1", "text B"]]);
});

// p-1's Save fails while its removal is pending (Delete hid it at once) and p-2's editor holds the
// editor, so p-1's text waits. The row is not gone until acpmux says so: when p-2's editor closes the text
// stays waiting (nothing goes to the composer); a refused removal brings the row back and the text
// reopens in its editor, an accepted one hands it to the composer.
async function failedSaveBehindPendingDelete() {
  const saves = new Map<string, { reject(error: Error): void }>();
  const removals: { resolve(ok: boolean): void }[] = [];
  const lost: [string, string][] = [];
  const container = installDom();
  const draw = (rows: typeof queue) =>
    root!.render(
      <ComposerQueue
        queue={rows}
        chat="c"
        t={t}
        onChange={(id) => new Promise<boolean>((_, reject) => saves.set(id, { reject }))}
        onRemove={() => new Promise<boolean>((resolve) => removals.push({ resolve }))}
        onLost={(text, id) => lost.push([id, text])}
      />,
    );
  await act(async () => {
    root = createRoot(container);
    draw(queue);
  });
  const saveAs = async (id: string, text: string) => {
    await startEdit(container, id);
    const field = container.querySelector<HTMLTextAreaElement>(`[data-prompt-id="${id}"] textarea`)!;
    await act(async () => {
      field.value = text;
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    await act(async () => {
      field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    });
  };
  await saveAs("p-1", "one edited");
  await saveAs("p-2", "two edited");
  // Delete p-1 while its Save is pending: hidden at once, its removal awaits acpmux.
  await act(async () => actions(container, "p-1")[1]!.click());
  await settle();
  expect(container.querySelector('[data-prompt-id="p-1"]')).toBeNull();
  const notConnected = () => Object.assign(new Error("not connected"), { code: "native.not_connected" });
  await act(async () => saves.get("p-2")!.reject(notConnected()));
  await settle();
  await act(async () => saves.get("p-1")!.reject(notConnected()));
  await settle();
  const editor = (id: string) => container.querySelector<HTMLTextAreaElement>(`[data-prompt-id="${id}"] textarea`);
  expect(editor("p-2")?.value).toBe("two edited");
  await act(async () => {
    editor("p-2")!.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    );
  });
  await settle();
  return { lost, removals, editor, redraw: (rows: typeof queue) => act(async () => draw(rows)) };
}

test("a failed save behind a pending delete waits for acpmux's answer; a refused delete reopens its editor", async () => {
  const run = await failedSaveBehindPendingDelete();
  expect(run.lost).toEqual([]);
  expect(run.editor("p-1")).toBeNull();
  await act(async () => run.removals[0]!.resolve(false));
  await settle();
  await settle();
  expect(run.editor("p-1")?.value).toBe("one edited");
  expect(run.lost).toEqual([]);
});

test("a failed save behind a pending delete hands its text to the composer once the delete took", async () => {
  const run = await failedSaveBehindPendingDelete();
  expect(run.lost).toEqual([]);
  await act(async () => run.removals[0]!.resolve(true));
  await run.redraw([queue[1]!]);
  await settle();
  await settle();
  expect(run.lost).toEqual([["p-1", "one edited"]]);
  expect(run.editor("p-1")).toBeNull();
});

for (const [name, error] of [
  ["timed out", { code: "native.timed_out" }],
  ["closed", { code: "transport.closed" }],
  ["failed (a reply lost or malformed after the edit applied)", { code: "native.failed" }],
] as const) {
  test(`a save that ${name} may already be applied: nothing is restored or reopened`, async () => {
    const run = await failedSave(error);
    expect(run.lost).toEqual([]);
    expect(run.editor()).toBeNull();
    expect(run.unhandled).toEqual([]);
  });
}

test("a save acpmux answers no to (the prompt already started) hands its text back to the composer", async () => {
  const run = await failedSave("answered-no");
  expect(run.lost).toEqual([["p-1", "first, reworded"]]);
  expect(run.editor()).toBeNull();
});

// The app's right-click menu is a native one (ui/nativeMenu.ts): it keeps the actions it opened
// with. Picked after the row turned out to be a teammate's, none runs.
test("a row menu opened before the row turned out to be a teammate's changes nothing", async () => {
  const { installNativeMenu } = await import("../../ui/nativeMenu");
  const touched: string[] = [];
  const container = installDom();
  const ana = { id: "tailnet:ana@example.com", name: "Ana" };
  let answer: (reply: unknown) => void = () => {};
  const offered: string[] = [];
  installNativeMenu(
    (request) =>
      new Promise((resolve) => {
        offered.push(...request.items.map((row) => row.id));
        answer = resolve;
      }),
  );
  const draw = (rows: Array<{ id: string; prompt: string; author?: typeof ana }>) =>
    root!.render(
      <ComposerQueue
        queue={rows}
        chat="c"
        t={t}
        onChange={async (id) => {
          touched.push(`change ${id}`);
          return true;
        }}
        onRemove={async (id) => {
          touched.push(`remove ${id}`);
          return true;
        }}
      />,
    );
  try {
    await act(async () => {
      root = createRoot(container);
      draw(queue);
    });
    const target = container.querySelector<HTMLElement>('[data-prompt-id="p-1"] .acpmux-queued-menu')!;
    await act(async () => {
      target.dispatchEvent(
        new dom!.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 60 }),
      );
    });
    await settle();
    const remove = offered.find((id) => id === "delete");
    expect(remove).toBeDefined();
    // Ana's authored record lands while the menu is up; then the person picks Delete.
    await act(async () => draw([{ ...queue[0]!, author: ana }, queue[1]!]));
    await act(async () => answer({ picked: remove }));
    await settle();
    expect(touched).toEqual([]);
  } finally {
    installNativeMenu(null);
  }
});

test("an edit pulled back while its images load, from a row that turned out a teammate's, takes nothing", async () => {
  const container = installDom();
  const ana = { id: "tailnet:ana@example.com", name: "Ana" };
  const touched: string[] = [];
  // Every read (the thumbnail's and the pull-back's) waits until the test lets them all finish.
  const reads: Array<(url: string | undefined) => void> = [];
  const rows = [{ id: "p-2", prompt: "see", images: [{ id: SHOT_A, mimeType: "image/png", name: "shot.png" }] }];
  const draw = (queue: Array<(typeof rows)[number] & { author?: typeof ana }>) =>
    root!.render(
      <ComposerQueue
        queue={queue}
        chat="c"
        t={t}
        readImage={() => new Promise<string | undefined>((resolve) => reads.push(resolve))}
        onCancelEdit={async (id) => {
          touched.push(`cancel ${id}`);
          return true;
        }}
      />,
    );
  await act(async () => {
    root = createRoot(container);
    draw(rows);
  });
  const pullBack = actions(container, "p-2").find((b) => b.dataset.action === "cancel-edit")!;
  await act(async () => pullBack.click());
  // Ana's authored record lands while the image is read; then the read finishes.
  await act(async () => draw([{ ...rows[0]!, author: ana }]));
  await act(async () => reads.splice(0).forEach((read) => read("data:image/png;base64,QQ==")));
  await settle();
  expect(touched).toEqual([]);
});

test("acpmux's ask to resume a subagent is a labelled row with the subagent's name, never its raw text", async () => {
  // Leo, 2026-10-30: "this looks weird and unrendered idk where it came from".
  const raw =
    'Your subagent "Cap context cost" (agent id af0cbece62b15d0e1) failed on a transient upstream error (529). Resume it';
  const container = await render(
    async () => true,
    async () => true,
    [{ id: "r-1", prompt: raw, retry: { name: "Cap context cost", agentId: "af0cbece62b15d0e1", error: "529" } }],
  );
  const text = container.querySelector<HTMLButtonElement>('[data-prompt-id="r-1"] .acpmux-queued-text')!;
  expect(text.querySelector('.acpmux-queued-kind[data-kind="retry"]')?.textContent).toBe(
    "composer.queuedSubagentRetry",
  );
  expect(text.textContent).toBe("composer.queuedSubagentRetryCap context cost");
  expect(text.textContent).not.toContain("agent id");
  // Opened, the error follows on its own line; the row keeps its actions.
  await act(async () => text.click());
  expect(text.querySelector(".acpmux-queued-detail")?.textContent).toBe("529");
  expect(actions(container, "r-1").length).toBe(3);
});

test("a truncated resume row's tooltip is the row's own text, never the raw prompt or its agent id", async () => {
  // Review (Codex astra) at 10ee1f0: a long name or a narrow pane showed acpmux's raw prompt on hover.
  const raw =
    'Your subagent "Cap context cost" (agent id af0cbece62b15d0e1) failed on a transient upstream error (529). ' +
    'Resume it with SendMessage to "af0cbece62b15d0e1": it picks up from its transcript.';
  const container = await render(
    async () => true,
    async () => true,
    [{ id: "r-1", prompt: raw, retry: { name: "Cap context cost", agentId: "af0cbece62b15d0e1", error: "529" } }],
  );
  const button = container.querySelector<HTMLButtonElement>('[data-prompt-id="r-1"] .acpmux-queued-text')!;
  // The clamp cuts its one line (a test DOM has no layout).
  const clamp = button.firstElementChild as HTMLElement;
  Object.defineProperty(clamp, "scrollWidth", { configurable: true, value: 400 });
  Object.defineProperty(clamp, "clientWidth", { configurable: true, value: 200 });
  // React makes onPointerEnter from a pointerover whose relatedTarget is outside the root.
  const Pointer =
    (dom!.window as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? dom!.window.MouseEvent;
  await act(async () => {
    button.dispatchEvent(new Pointer("pointerover", { bubbles: true, relatedTarget: dom!.window.document.body }));
  });
  expect(button.title).toBe("composer.queuedSubagentRetry Cap context cost\n529");
  expect(button.title).not.toContain("agent id");
  expect(button.title).not.toContain("af0cbece62b15d0e1");
  expect(button.title).not.toContain("SendMessage");
});

test("shownText is the prompt for the person's rows, and the resume's label, name and error for acpmux's", () => {
  expect(shownText({ id: "p", prompt: "hello there" }, t)).toBe("hello there");
  expect(shownText({ id: "r", prompt: "Your subagent … (agent id x1)", retry: { agentId: "x1" } }, t)).toBe(
    "composer.queuedSubagentRetry x1",
  );
});

// Cancel and edit takes the row back with the text it shows. A Save of the row still out would
// change that text, and one failing after the row left would restore its own beside it, so cancel and
// edit waits for the Save's answer: nothing is taken back, and nothing typed is lost or shown twice.
async function cancelAndEditWhileSaving(slowImages = false) {
  const saves: { resolve(ok: boolean): void; reject(error: Error): void }[] = [];
  const reads: ((url: string | undefined) => void)[] = [];
  const taken: [string, string][] = [];
  const lost: [string, string][] = [];
  const first = {
    ...queue[0]!,
    ...(slowImages ? { images: [{ id: SHOT_A, mimeType: "image/png", name: "shot.png" }] } : {}),
  };
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={[first, queue[1]!]}
        chat="c"
        t={t}
        readImage={slowImages ? () => new Promise<string | undefined>((resolve) => reads.push(resolve)) : undefined}
        onChange={() => new Promise<boolean>((resolve, reject) => saves.push({ resolve, reject }))}
        onRemove={async () => true}
        onCancelEdit={async (id, text) => {
          taken.push([id, text]);
          return true;
        }}
        onLost={(text, id) => lost.push([id, text])}
      />,
    );
  });
  const cancel = () =>
    container.querySelector<HTMLButtonElement>('[data-prompt-id="p-1"] [data-action="cancel-edit"]')!;
  const save = async () => {
    await startEdit(container, "p-1");
    const field = container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')!;
    await act(async () => {
      field.value = "first, reworded";
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    await act(async () => {
      field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    });
  };
  const editor = () => container.querySelector<HTMLTextAreaElement>('[data-prompt-id="p-1"] textarea')?.value ?? null;
  return { saves, reads, taken, lost, cancel, save, editor };
}

test("cancel and edit does nothing while a Save of the row is out, and the failed Save's text is not lost", async () => {
  const run = await cancelAndEditWhileSaving();
  await run.save();
  await act(async () => run.cancel().click());
  await settle();
  expect(run.taken).toEqual([]);
  await act(async () => run.saves[0]!.reject(Object.assign(new Error("failed"), { code: "native.not_connected" })));
  await settle();
  expect(run.editor()).toBe("first, reworded");
  expect(run.lost).toEqual([]);
});

test("cancel and edit works again once the Save is answered", async () => {
  const run = await cancelAndEditWhileSaving();
  await run.save();
  await act(async () => run.saves[0]!.resolve(true));
  await settle();
  await act(async () => run.cancel().click());
  await settle();
  expect(run.taken).toEqual([["p-1", "first"]]);
});

test("a Save begun while cancel and edit reads the row's images keeps the row queued", async () => {
  const run = await cancelAndEditWhileSaving(true);
  await act(async () => run.cancel().click());
  await run.save();
  await act(async () => run.reads.forEach((finish) => finish("data:image/png;base64,QQ==")));
  await settle();
  expect(run.taken).toEqual([]);
  await act(async () => run.saves[0]!.reject(Object.assign(new Error("failed"), { code: "native.not_connected" })));
  await settle();
  expect(run.editor()).toBe("first, reworded");
  expect(run.lost).toEqual([]);
});

test("a Save begun and answered while cancel and edit reads the row's images keeps the row queued", async () => {
  const run = await cancelAndEditWhileSaving(true);
  await act(async () => run.cancel().click());
  await run.save();
  await act(async () => run.saves[0]!.reject(Object.assign(new Error("failed"), { code: "native.not_connected" })));
  await settle();
  await act(async () => run.reads.forEach((finish) => finish("data:image/png;base64,QQ==")));
  await settle();
  expect(run.taken).toEqual([]);
  expect(run.editor()).toBe("first, reworded");
  expect(run.lost).toEqual([]);
});
