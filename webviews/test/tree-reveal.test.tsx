// ui/Tree reveals a row it has not mounted: a selection set from outside (the store restoring it, a
// host's reveal, a refresh that keeps it), End, typeahead and a selection that comes back after it
// left the lines all mount that row and scroll it into the viewport, at 1,000 lines with the row
// near the end. The tree stays the one Tab stop: rows hold nothing focusable.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import type { Bookmark } from "../src/pages/bookmarks/types";
import type { TreeLine } from "../src/ui/Tree";
import { settleReact } from "./support/domTeardown";
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
const VIEWPORT = 600;
const ROW = 26;
const treeSizes = (element: HTMLElement) => (element.classList.contains("ui-tree") ? VIEWPORT : ROW);

// Set before React and TanStack load: @tanstack/react-virtual picks useLayoutEffect (as in a browser)
// only when `document` exists as it loads, else its effects run after the tree's own.
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
const { Tree } = await import("../src/ui/Tree");
const { BookmarksPage } = await import("../src/pages/bookmarks/BookmarksPage");
const { BookmarksStore } = await import("../src/pages/bookmarks/store");
const { MockBookmarksProvider } = await import("../src/pages/bookmarks/mockProvider");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const bookmarkStrings = (await import("../src/pages/bookmarks/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;

const N = 1_000;
const key = (at: number) => `f${String(at).padStart(4, "0")}`;

/** `n` flat files; the first `listed` of them are lines (a folder not yet listed holds the rest). */
function lines(n: number): TreeLine[] {
  return Array.from({ length: n }, (_, at) => ({
    kind: "item",
    key: key(at),
    depth: 0,
    text: key(at),
    expandable: false,
    expanded: false,
    content: key(at),
  }));
}

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

interface Control {
  select(key: string | undefined): void;
  list(lines: TreeLine[]): void;
}

async function mount(initial: { lines: TreeLine[]; selected?: string }) {
  const control = {} as Control;
  function Harness() {
    const [selected, setSelected] = useState(initial.selected);
    const [shown, setShown] = useState(initial.lines);
    control.select = setSelected;
    control.list = setShown;
    return (
      <Tree
        lines={shown}
        selected={selected}
        label="Files"
        onSelect={setSelected}
        onExpand={() => {}}
        onActivate={() => {}}
      />
    );
  }
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  act(() => root!.render(<Harness />));
  await settle();
  await settle();
  return { control, element: host.querySelector<HTMLElement>('[role="tree"]')! };
}

async function press(element: HTMLElement, key: string) {
  await act(async () => {
    element.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
  await settle();
}

/** The row of `name` is mounted, selected, named by aria-activedescendant and inside the viewport. */
function expectRevealed(element: HTMLElement, name: string) {
  const row = [...element.querySelectorAll<HTMLElement>('[role="treeitem"]')].find((node) => node.textContent === name);
  expect(row?.getAttribute("aria-selected")).toBe("true");
  expect(element.getAttribute("aria-activedescendant")).toBe(row!.id);
  const top = Number(row!.dataset.index) * ROW;
  expect(top).toBeGreaterThanOrEqual(element.scrollTop);
  expect(top + ROW).toBeLessThanOrEqual(element.scrollTop + VIEWPORT);
}

const TARGET = key(N - 3);

test("a selection given at mount (restored from the store) far down is mounted and scrolled to", async () => {
  const { element } = await mount({ lines: lines(N), selected: TARGET });
  expectRevealed(element, TARGET);
});

test("a selection set from outside (a host reveal, a refresh that keeps it) far down is revealed", async () => {
  const { control, element } = await mount({ lines: lines(N), selected: key(0) });
  await act(async () => control.select(TARGET));
  await settle();
  expectRevealed(element, TARGET);
});

test("End and typeahead reach a row far down and reveal it", async () => {
  const { element } = await mount({ lines: lines(N), selected: key(0) });
  await press(element, "End");
  expectRevealed(element, key(N - 1));
  await press(element, "Home");
  expectRevealed(element, key(0));
  // Typeahead: "f0997" picks one row near the end.
  for (const letter of TARGET) await press(element, letter);
  expectRevealed(element, TARGET);
});

test("a selection set before its row is listed (a folder that opens later) is revealed once listed", async () => {
  const { control, element } = await mount({ lines: lines(10), selected: TARGET });
  await act(async () => control.list(lines(N)));
  await settle();
  expectRevealed(element, TARGET);
});

test("a selection that leaves the lines and comes back after a scroll away is revealed again", async () => {
  // Bookmarks: a search clears the tree's selection, the person scrolls the tree, then Show in
  // Folder picks the same folder. Files: a collapse lifts the selection to the folder, and back.
  const { control, element } = await mount({ lines: lines(N), selected: TARGET });
  expectRevealed(element, TARGET);
  await act(async () => control.select(undefined));
  await act(async () => {
    element.scrollTop = 0;
    element.dispatchEvent(new dom.window.Event("scroll"));
  });
  await settle();
  await act(async () => control.select(TARGET));
  await settle();
  expectRevealed(element, TARGET);
});

test("the tree is the one Tab stop wherever it is scrolled (rows hold nothing focusable)", async () => {
  const { element } = await mount({ lines: lines(N), selected: key(0) });
  await press(element, "End");
  const tabbable = [
    ...host.querySelectorAll<HTMLElement>("a[href], button, input, select, textarea, [tabindex]"),
  ].filter((node) => node.tabIndex >= 0);
  expect(tabbable).toEqual([element]);
  // The window coming forward focuses the tree, and the selected row it names is mounted.
  element.blur();
  await act(async () => dom.window.dispatchEvent(new dom.window.Event("focus")));
  expect(dom.window.document.activeElement).toBe(element);
  expect(dom.window.document.getElementById(element.getAttribute("aria-activedescendant")!)).not.toBeNull();
});

test("Bookmarks: Show in Folder after a search reveals its folder far down the tree again", async () => {
  // The bar holds N folders; the last but two holds one bookmark.
  const folders: Bookmark[] = Array.from({ length: N }, (_, at) => ({
    id: `folder-${at}`,
    browser_profile_id: "default",
    parent: "bar",
    kind: "folder",
    index: at,
    title: key(at),
    created_ms: 0,
  }));
  const far = folders[N - 3]!;
  const page: Bookmark = {
    id: "page",
    browser_profile_id: "default",
    parent: far.id,
    kind: "url",
    index: 0,
    title: "Saved page",
    url: "https://saved.example/",
    created_ms: 0,
  };
  const store = new BookmarksStore(new MockBookmarksProvider([...folders, page]), { newKey: () => "k" });
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host} dir="ltr">
        <BookmarksPage store={store} strings={createStrings(bookmarkStrings, ["en"])} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  await settle();
  const element = host.querySelector<HTMLElement>('[role="tree"]')!;
  const at = (name: string) =>
    [...element.querySelectorAll<HTMLElement>('[role="treeitem"]')].find((node) => node.textContent === name);
  const inView = (name: string) => {
    const row = at(name);
    expect(row?.getAttribute("aria-selected")).toBe("true");
    // Line 0 is the bar, then its folders, then the other root.
    const top = Number(row!.dataset.index) * ROW;
    expect(top).toBeGreaterThanOrEqual(element.scrollTop);
    expect(top + ROW).toBeLessThanOrEqual(element.scrollTop + VIEWPORT);
  };
  await act(async () => store.reveal(page.id));
  await settle();
  inView(far.title);
  // A search: the tree selects nothing, and the person scrolls it back to the top.
  await act(async () => store.setText("saved"));
  await settle();
  await act(async () => {
    element.scrollTop = 0;
    element.dispatchEvent(new dom.window.Event("scroll"));
  });
  await settle();
  // Show in Folder on the result: the same folder again.
  await act(async () => store.reveal(page.id));
  await settle();
  inView(far.title);
});

test("Bookmarks: Show in Folder for a folder 3 levels deep in collapsed folders far down opens them and reveals it", async () => {
  // 1,000 bookmarks: the bar holds 996 folders; the last but two holds Outer > Middle > Inner, all
  // three collapsed, and Inner holds the target folder with one bookmark in it.
  const flat = N - 4;
  const node = (id: string, parent: string, index: number, title: string): Bookmark => ({
    id,
    browser_profile_id: "default",
    parent,
    kind: "folder",
    index,
    title,
    created_ms: 0,
  });
  const folders = Array.from({ length: flat }, (_, at) => node(`folder-${at}`, "bar", at, key(at)));
  const outer = folders[flat - 3]!;
  const middle = node("middle", outer.id, 0, "Middle");
  const inner = node("inner", middle.id, 0, "Inner");
  const target = node("target", inner.id, 0, "Target");
  const page: Bookmark = { ...node("page", target.id, 0, "Saved page"), kind: "url", url: "https://saved.example/" };
  const all = [...folders, middle, inner, target, page];
  expect(all.length).toBe(N);
  const store = new BookmarksStore(new MockBookmarksProvider(all), { newKey: () => "k" });
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host} dir="ltr">
        <BookmarksPage store={store} strings={createStrings(bookmarkStrings, ["en"])} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  await settle();
  await act(async () => {
    for (const folder of [outer, middle, inner]) store.setCollapsed(folder.id, true);
  });
  await settle();
  const element = host.querySelector<HTMLElement>('[role="tree"]')!;
  const at = (name: string) =>
    [...element.querySelectorAll<HTMLElement>('[role="treeitem"]')].find((row) => row.textContent === name);
  expect(at(inner.title)).toBeUndefined();
  // Show in Folder on a search result.
  await act(async () => store.setText("target"));
  await settle();
  let updates = 0;
  const stop = store.subscribe(() => (updates += 1));
  await act(async () => store.reveal(target.id));
  stop();
  await settle();
  // The ancestors open in the one update that selects it.
  expect(updates).toBe(1);
  // The tree lists the target under its folder, and selects that folder (the one the list shows)
  // and scrolls it into view.
  expect(at(target.title)).toBeDefined();
  const shown = at(inner.title);
  expect(shown?.getAttribute("aria-selected")).toBe("true");
  expect(element.getAttribute("aria-activedescendant")).toBe(shown!.id);
  const top = Number(shown!.dataset.index) * ROW;
  expect(top).toBeGreaterThan(VIEWPORT);
  expect(top).toBeGreaterThanOrEqual(element.scrollTop);
  expect(top + ROW).toBeLessThanOrEqual(element.scrollTop + VIEWPORT);
  // The list shows the folder's contents with the target selected.
  const listed = [...host.querySelectorAll<HTMLElement>('[role="grid"] [role="row"]')].find((row) =>
    row.textContent?.includes(target.title),
  );
  expect(listed?.getAttribute("aria-selected")).toBe("true");
  // Still about one viewport each side of 23 lines, not the 1,000.
  expect(element.querySelectorAll('[role="treeitem"]').length).toBeLessThanOrEqual(70);
  const snap = store.getSnapshot();
  expect(snap.folder).toBe(inner.id);
  expect(snap.selection).toEqual([target.id]);
  expect(
    [outer, middle, inner].filter((folder) => snap.collapsed.has(folder.id)).map((folder) => folder.title),
  ).toEqual([]);
});
