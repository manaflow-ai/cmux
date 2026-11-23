import { afterEach, expect, jest, test } from "bun:test";
import { act, useCallback } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { TRANSIENT_SHOW_MS, useAfterDelay, useSettledItems } from "./afterDelay";
import { settleReact } from "../../../test/support/domTeardown";

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
  jest.useRealTimers();
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

function Probe({ active, ms }: { active: boolean; ms: number }) {
  return <span>{useAfterDelay(active, ms) ? "shown" : "hidden"}</span>;
}

const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

async function render(container: HTMLElement, active: boolean, ms: number) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<Probe active={active} ms={ms} />);
  });
}

test("shows only once active has held for the delay, and hides at once when it ends", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await render(container, true, 40);
  expect(container.textContent).toBe("hidden");
  await wait(39);
  expect(container.textContent).toBe("hidden");
  await wait(1);
  expect(container.textContent).toBe("shown");
  await render(container, false, 40);
  expect(container.textContent).toBe("hidden");
});

test("a break restarts the wait: a stretch shorter than the delay never shows", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await render(container, true, 60);
  await wait(30);
  await render(container, false, 60);
  await render(container, true, 60);
  await wait(59);
  expect(container.textContent).toBe("hidden");
  await wait(1);
  expect(container.textContent).toBe("shown");
});

test("a delay of 0 shows at once, and inactive never shows", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await render(container, true, 0);
  expect(container.textContent).toBe("shown");
  await render(container, false, 0);
  expect(container.textContent).toBe("hidden");
});

// Leo, 2026-11-17: "i also dont like seeing the flicker flash of the Queued blah blah blah
// something". An entry that comes and goes at a turn's boundary never paints.
type Item = { id: string };
const itemId = (item: Item) => item.id;
const drawn: (readonly Item[])[] = [];

function ListProbe({ items, scope, immediate }: { items: readonly Item[]; scope: string; immediate?: string }) {
  const isImmediate = useCallback((item: Item) => item.id === immediate, [immediate]);
  const shown = useSettledItems(items, itemId, scope, TRANSIENT_SHOW_MS, isImmediate);
  drawn.push(shown);
  return <span>{shown.map((item) => item.id).join(",")}</span>;
}

async function renderList(container: HTMLElement, items: readonly Item[], scope = "chat-1", immediate?: string) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<ListProbe items={items} scope={scope} {...(immediate ? { immediate } : {})} />);
  });
}

test("the transient bound is 200 ms", () => {
  expect(TRANSIENT_SHOW_MS).toBe(200);
});

test("an entry that lasts 150 ms never paints", async () => {
  jest.useFakeTimers();
  drawn.length = 0;
  const container = installDom();
  await renderList(container, []);
  await renderList(container, [{ id: "q1" }]);
  await wait(150);
  await renderList(container, []);
  await wait(500);
  expect(drawn.some((shown) => shown.some((item) => item.id === "q1"))).toBe(false);
  expect(container.textContent).toBe("");
});

test("an entry that lasts 250 ms shows at 200 ms and goes at once when it ends", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await renderList(container, []);
  const entry = { id: "q1" };
  await renderList(container, [entry]);
  await wait(199);
  expect(container.textContent).toBe("");
  await wait(1);
  expect(container.textContent).toBe("q1");
  await wait(50);
  await renderList(container, []);
  expect(container.textContent).toBe("");
});

test("entries there at the first render, or when the chat changes, show at once", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await renderList(container, [{ id: "a" }, { id: "b" }]);
  expect(container.textContent).toBe("a,b");
  await renderList(container, [{ id: "c" }], "chat-2");
  expect(container.textContent).toBe("c");
});

test("an immediate entry shows at once; the array keeps its identity while nothing shown changes", async () => {
  jest.useFakeTimers();
  drawn.length = 0;
  const container = installDom();
  const items = [{ id: "a" }];
  await renderList(container, items);
  expect(drawn.at(-1)).toBe(items);
  const more = [...items, { id: "held" }, { id: "late" }];
  await renderList(container, more, "chat-1", "held");
  expect(container.textContent).toBe("a,held");
  const first = drawn.at(-1);
  await renderList(container, more, "chat-1", "held");
  expect(drawn.at(-1)).toBe(first);
  await wait(200);
  expect(container.textContent).toBe("a,held,late");
  expect(drawn.at(-1)).toBe(more);
});
