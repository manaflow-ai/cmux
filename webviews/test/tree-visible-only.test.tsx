// ui/Tree draws what is visible (the visible-only rule), through the Files page: at 1,000 and 10,000
// open entries the tree mounts the same rows and DOM nodes, and a selection, a one-row scroll, a
// listing that renames one file and the opening of one folder draw again only the rows they change.
// Before, every open entry was a mounted row and each render drew every row again: rows were not
// memoized, took new handlers each render, and the page built every line anew on each selection.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { MockTree } from "../src/pages/files/mockProvider";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "customElements",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

/** The tree is a 600 px viewport of 26 px rows (jsdom has no layout). */
const treeSizes = (element: HTMLElement) => (element.classList.contains("ui-tree") ? 600 : 26);

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/files/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  installVirtualSizes(dom.window, treeSizes);
  // The tree's content is its mounted rows and the blocks standing in for the rest, in the flow.
  Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      let height = 0;
      for (const child of this.children)
        height += parseFloat((child as HTMLElement).style.height) || treeSizes(child as HTMLElement);
      return Math.max(height, treeSizes(this));
    },
  });
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { FilesPage } = await import("../src/pages/files/FilesPage");
const { FilesStore } = await import("../src/pages/files/store");
const { MockFilesProvider } = await import("../src/pages/files/mockProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/files/generated/strings.json")).default;

const FOLDERS = 10;

/** A closed folder of five files first, then FOLDERS open folders holding `n` entries in all. */
function files(n: number): MockTree {
  const tree: MockTree = { "a-closed": Object.fromEntries(Array.from({ length: 5 }, (_, at) => [`c${at}.ts`, null])) };
  const each = n / FOLDERS - 1;
  for (let folder = 0; folder < FOLDERS; folder++)
    tree[`d${String(folder).padStart(2, "0")}`] = Object.fromEntries(
      Array.from({ length: each }, (_, at) => [`f${String(at).padStart(4, "0")}.ts`, null]),
    );
  return tree;
}

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

async function mount(n: number) {
  const tree = files(n);
  const provider = new MockFilesProvider(tree);
  const store = new FilesStore(provider);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  act(() => root!.render(<FilesPage store={store} strings={createStrings(table)} />));
  await act(() => store.start());
  await act(async () => {
    for (let folder = 0; folder < FOLDERS; folder++) store.expand(`d${String(folder).padStart(2, "0")}`);
  });
  await settle();
  return { tree, store, element: host.querySelector<HTMLElement>('[role="tree"]')! };
}

const rows = () => host.querySelectorAll('[role="treeitem"]').length;
// The nearest component above each row: the row itself once it is one, else the whole tree.
const renders = mountedRowRenders(() => host.querySelectorAll('[role="treeitem"]'));
const nodes = (element: HTMLElement) => element.querySelectorAll("*").length;

async function press(element: HTMLElement, key: string) {
  await act(async () => {
    element.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
}

/** Mounted rows, DOM nodes and the row renders of a selection, a one-row scroll, a one-file change
 *  and one folder's opening. */
async function measure(n: number) {
  const { tree, store, element } = await mount(n);
  const mounted = { rows: rows(), nodes: nodes(element) };

  renders.mark();
  await press(element, "ArrowDown");
  const select = renders.since();

  const rects = { calls: 0 };
  const original = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    rects.calls++;
    return original.call(this);
  };
  renders.mark();
  await act(async () => {
    element.scrollTop += 26;
    element.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = { renders: renders.since(), rects: rects.calls };
  dom.window.Element.prototype.getBoundingClientRect = original;

  renders.mark();
  const folder = tree.d00 as MockTree;
  delete folder["f0001.ts"];
  folder["f0001-renamed.ts"] = null;
  await act(async () => store.refresh());
  const change = renders.since();

  renders.mark();
  await act(async () => store.expand("a-closed"));
  await settle();
  const expand = renders.since();
  return { n, mounted, select, scroll, change, expand };
}

test("1,000 and 10,000 open entries mount the same rows, and one event draws only the rows it changed", async () => {
  // Each run is checked before the next: a tree that mounts every entry fails at 1,000 already.
  const check = (run: Awaited<ReturnType<typeof measure>>) => {
    console.log(JSON.stringify(run));
    // Rule 1: the viewport's rows (600 / 26) and about one viewport each side, not the tree.
    expect(run.mounted.rows).toBeGreaterThan(10);
    expect(run.mounted.rows).toBeLessThanOrEqual(70);
    // Rule 2: a selection draws the row it leaves and the row it takes.
    expect(run.select).toBeLessThanOrEqual(2);
    // One row's scroll draws only the rows it brings in; the mounted ones keep their place.
    expect(run.scroll.renders).toBeLessThanOrEqual(2);
    // A listing that renames one file draws that row alone.
    expect(run.change).toBeLessThanOrEqual(1);
    // Opening a folder draws it and its five rows; the rows it moves down do not draw again.
    expect(run.expand).toBeLessThanOrEqual(6);
  };
  const small = await measure(1_000);
  check(small);
  act(() => root?.unmount());
  const large = await measure(10_000);
  check(large);
  expect(Math.abs(large.mounted.rows - small.mounted.rows)).toBeLessThanOrEqual(small.mounted.rows * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);
  // Rule 3: a scroll reads no row's layout, at any length.
  expect(large.scroll.rects).toBe(small.scroll.rects);
}, 60_000);

test("Down far past the window keeps the selected row mounted and named by aria-activedescendant", async () => {
  const { element } = await mount(1_000);
  for (let step = 0; step < 120; step++) await press(element, "ArrowDown");
  await settle();
  const active = element.getAttribute("aria-activedescendant")!;
  const row = dom.window.document.getElementById(active);
  expect(row?.getAttribute("aria-selected")).toBe("true");
  expect(element.scrollTop).toBeGreaterThan(600);
  // Each row says its level and its place among its siblings, as nesting is flattened.
  expect(row?.getAttribute("aria-level")).toBe("2");
  expect(Number(row?.getAttribute("aria-posinset"))).toBeGreaterThan(1);
  expect(row?.getAttribute("aria-setsize")).toBe(String(1_000 / FOLDERS - 1));
  expect(rows()).toBeLessThanOrEqual(70);
  // Home and Left come back to the top, and the first row mounts again.
  await press(element, "ArrowLeft");
  await press(element, "Home");
  await settle();
  expect(dom.window.document.getElementById(element.getAttribute("aria-activedescendant")!)?.textContent).toBe(
    "a-closed",
  );
});
