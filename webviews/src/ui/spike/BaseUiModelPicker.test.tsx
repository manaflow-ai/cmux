// SPIKE: the Base UI model picker composition keeps the picker's gestures and keys:
// press-drag-release picks a row, Ctrl-N/P/J/K and the arrows move the highlight with DOM focus in
// the search field, Return picks, Escape closes and hands focus back to the trigger.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { BaseUiModelPicker, type SpikeHarness } from "./BaseUiModelPicker";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "MouseEvent",
  "PointerEvent",
  "KeyboardEvent",
  "NodeFilter",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

const harnesses: SpikeHarness[] = [
  {
    id: "claude",
    name: "Claude Code",
    models: [
      { value: "opus", label: "Opus 5.5", group: "Latest" },
      { value: "sonnet", label: "Sonnet 5.5", group: "Latest" },
      { value: "haiku", label: "Haiku 5.5", group: "Older" },
    ],
  },
  { id: "codex", name: "Codex", models: [{ value: "sol", label: "GPT-6.1-Sol" }] },
];

function mount(picks: string[]) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const w = dom.window as unknown as Record<string, unknown>;
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: w.Node,
    HTMLElement: w.HTMLElement,
    HTMLInputElement: w.HTMLInputElement,
    Element: w.Element,
    MouseEvent: w.MouseEvent,
    PointerEvent: w.PointerEvent,
    KeyboardEvent: w.KeyboardEvent,
    NodeFilter: w.NodeFilter,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: w.requestAnimationFrame,
    cancelAnimationFrame: w.cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() =>
    root!.render(
      <BaseUiModelPicker
        harnesses={harnesses}
        harness="claude"
        model="opus"
        onPick={(h, m) => picks.push(`${h}/${m}`)}
      />,
    ),
  );
  return dom.window.document;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const flush = () =>
  act(async () => {
    for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  });
const trigger = (doc: Document) => doc.querySelector<HTMLButtonElement>(".spike-mp-trigger")!;
const input = (doc: Document) => doc.querySelector<HTMLInputElement>(".spike-mp-search")!;
const rows = (doc: Document) => [...doc.querySelectorAll<HTMLElement>(".spike-mp-row")];
const highlighted = (doc: Document) => doc.querySelector<HTMLElement>(".spike-mp-row[data-highlighted]")?.textContent;

function pointer(target: Element, type: string, init: PointerEventInit = {}) {
  const View = target.ownerDocument.defaultView!.PointerEvent;
  target.dispatchEvent(
    new View(type, { bubbles: true, cancelable: true, pointerType: "mouse", pointerId: 1, button: 0, ...init }),
  );
}
function mouse(target: Element, type: string, init: MouseEventInit = {}) {
  const View = target.ownerDocument.defaultView!.MouseEvent;
  target.dispatchEvent(new View(type, { bubbles: true, cancelable: true, button: 0, ...init }));
}
async function key(target: Element, keyName: string, init: KeyboardEventInit = {}) {
  const View = target.ownerDocument.defaultView!.KeyboardEvent;
  await act(async () => {
    target.dispatchEvent(new View("keydown", { key: keyName, bubbles: true, cancelable: true, ...init }));
  });
  await flush();
}

async function openByPress(doc: Document) {
  await act(async () => {
    pointer(trigger(doc), "pointerdown", { clientX: 10, clientY: 10 });
    mouse(trigger(doc), "mousedown", { clientX: 10, clientY: 10 });
  });
  await flush();
}

test("a press opens it in place, the trigger stays lit, and the search field has DOM focus", async () => {
  const doc = mount([]);
  await openByPress(doc);
  expect(doc.querySelector(".spike-mp")).not.toBeNull();
  expect(trigger(doc).hasAttribute("data-popup-open")).toBe(true);
  expect(doc.activeElement).toBe(input(doc));
  // autoHighlight="always": the first row is highlighted before any typing.
  expect(highlighted(doc)).toBe("Opus 5.5");
});

test("press on the trigger, drag onto a row, release: picks it and closes", async () => {
  const picks: string[] = [];
  const doc = mount(picks);
  await openByPress(doc);
  const sonnet = rows(doc).find((row) => row.textContent === "Sonnet 5.5")!;
  await act(async () => {
    pointer(sonnet, "pointermove", { clientX: 40, clientY: 80 });
    mouse(sonnet, "mousemove", { clientX: 40, clientY: 80 });
  });
  await flush();
  expect(highlighted(doc)).toBe("Sonnet 5.5");
  await act(async () => {
    pointer(sonnet, "pointerup", { clientX: 40, clientY: 80 });
    mouse(sonnet, "mouseup", { clientX: 40, clientY: 80 });
  });
  await flush();
  expect(picks).toEqual(["claude/sonnet"]);
  expect(trigger(doc).hasAttribute("data-popup-open")).toBe(false);
});

test("drag-release on the search field keeps it open; on a rail tab switches harness", async () => {
  const picks: string[] = [];
  const doc = mount(picks);
  await openByPress(doc);
  await act(async () => {
    pointer(input(doc), "pointermove", { clientX: 60, clientY: 40 });
    pointer(input(doc), "pointerup", { clientX: 60, clientY: 40 });
    mouse(input(doc), "mouseup", { clientX: 60, clientY: 40 });
  });
  await flush();
  expect(doc.querySelector(".spike-mp")).not.toBeNull();
  // A second gesture: close by pressing the trigger, then press again and drag onto the Codex tab.
  await openByPress(doc);
  await openByPress(doc);
  const codexTab = doc.querySelector<HTMLElement>('[data-spike-harness="codex"]')!;
  await act(async () => {
    pointer(codexTab, "pointermove", { clientX: 20, clientY: 60 });
    pointer(codexTab, "pointerup", { clientX: 20, clientY: 60 });
    mouse(codexTab, "mouseup", { clientX: 20, clientY: 60 });
  });
  await flush();
  expect(doc.querySelector(".spike-mp")).not.toBeNull();
  expect(rows(doc).map((row) => row.textContent)).toEqual(["GPT-6.1-Sol"]);
  expect(doc.activeElement).toBe(input(doc));
  expect(picks).toEqual([]);
});

test("Ctrl-N/P/J/K and the arrows move the highlight with focus in the field; Return picks", async () => {
  const picks: string[] = [];
  const doc = mount(picks);
  await openByPress(doc);
  const field = input(doc);
  expect(highlighted(doc)).toBe("Opus 5.5");
  await key(field, "n", { ctrlKey: true });
  expect(highlighted(doc)).toBe("Sonnet 5.5");
  await key(field, "j", { ctrlKey: true });
  expect(highlighted(doc)).toBe("Haiku 5.5");
  await key(field, "k", { ctrlKey: true });
  expect(highlighted(doc)).toBe("Sonnet 5.5");
  await key(field, "p", { ctrlKey: true });
  expect(highlighted(doc)).toBe("Opus 5.5");
  await key(field, "ArrowDown");
  expect(highlighted(doc)).toBe("Sonnet 5.5");
  expect(doc.activeElement).toBe(field);
  await key(field, "Enter");
  expect(picks).toEqual(["claude/sonnet"]);
});

test("Ctrl-] steps the harness rail from the search field", async () => {
  const doc = mount([]);
  await openByPress(doc);
  await key(input(doc), "]", { ctrlKey: true });
  expect(rows(doc).map((row) => row.textContent)).toEqual(["GPT-6.1-Sol"]);
  expect(doc.activeElement).toBe(input(doc));
});

test("typing filters with focus kept; a typed miss says No matching models", async () => {
  const doc = mount([]);
  await openByPress(doc);
  const field = input(doc);
  const setValue = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(field, "son");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await flush();
  expect(rows(doc).map((row) => row.textContent)).toEqual(["Sonnet 5.5"]);
  expect(doc.activeElement).toBe(field);
  await act(async () => {
    setValue.call(field, "zzz");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await flush();
  expect(doc.querySelector(".spike-mp-status")?.textContent).toBe("No matching models");
});

test("Escape closes it and returns focus to the trigger", async () => {
  const doc = mount([]);
  await openByPress(doc);
  await key(input(doc), "Escape");
  await flush();
  expect(trigger(doc).hasAttribute("data-popup-open")).toBe(false);
  expect(doc.activeElement).toBe(trigger(doc));
});
