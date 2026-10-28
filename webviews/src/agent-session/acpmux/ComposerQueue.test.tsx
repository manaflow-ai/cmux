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
