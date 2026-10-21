// A queued prompt's row shows its actions (Leo, 2026-10-20: "where the hell is the edit button?"):
// Edit, Remove, Stop & send and Send now, each a button named by its tooltip, and each does what
// it says through `_acpmux/queue_edit` or the withdraw.
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

test("every queued row shows Edit, Remove, Stop & send and Send now, each with its tooltip", async () => {
  const container = await render(
    async () => true,
    async () => true,
  );
  for (const entry of queue) {
    const buttons = actions(container, entry.id);
    expect(buttons.map((b) => b.dataset.action)).toEqual(["edit", "remove", "stop", "send"]);
    expect(buttons.map((b) => b.title)).toEqual([
      "composer.queueEdit",
      "composer.queueRemove",
      "composer.queueStopAndSend",
      "composer.queueSendNow",
    ]);
    for (const b of buttons) expect(b.getAttribute("aria-label")).toBe(b.title);
  }
});

test("Stop & send stops the turn for the prompt, Send now steers it, Remove withdraws it", async () => {
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
  const [, , stop, send] = actions(container, "p-2");
  await act(async () => stop.click());
  await act(async () => send.click());
  const [, remove] = actions(container, "p-1");
  await act(async () => remove.click());
  expect(edits).toEqual([
    ["p-2", { op: "interrupt" }],
    ["p-2", { op: "send_now" }],
  ]);
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

test("a held ⌘↩ on a row sends that row once and keeps focus on it", async () => {
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
    row.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Enter", metaKey: true, repeat, bubbles: true }),
    );
  await act(async () => {
    press(false);
    press(true);
    press(true);
  });
  expect(edits).toEqual([["p-1", { op: "send_now" }]]);
  expect(dom!.window.document.activeElement).toBe(row);
});
