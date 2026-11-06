// The Bookmarks page driven through its DOM over the mock provider: search focused on open, the
// keys of the Swift manager (Down selects, Return enters a folder, Delete removes), the row and
// empty-area menus and the More menu. The list virtualizes, so with no layout only the active row
// draws; each step reads that row.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
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

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/bookmarks/",
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
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const menu of dom.window.document.querySelectorAll('[role="menu"]')) menu.remove();
});

afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { BookmarksPage } = await import("../src/pages/bookmarks/BookmarksPage");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/bookmarks/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockBookmarksProvider } = await import("../src/pages/bookmarks/mockProvider");
const { BookmarksStore } = await import("../src/pages/bookmarks/store");
const { BookmarkOps } = await import("../src/pages/bookmarks/types");

async function mount() {
  const provider = new MockBookmarksProvider();
  const store = new BookmarksStore(provider, { newKey: () => "k" });
  const strings = createStrings(table, ["en"]);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host} dir="ltr">
        <BookmarksPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  return { provider, store };
}

const search = () => host.querySelector<HTMLInputElement>(".bm-search")!;
const activeRow = () => host.querySelector<HTMLElement>('.bm-row[tabindex="0"]');
const menuLabels = () =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].map((item) => item.textContent);

async function key(element: HTMLElement, name: string) {
  await act(async () => {
    element.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  });
}

async function contextMenu(element: HTMLElement) {
  await act(async () => {
    element.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    );
  });
}

test("the search field has focus on open and Down selects the first row", async () => {
  await mount();
  expect(dom.window.document.activeElement).toBe(search());
  await key(search(), "ArrowDown");
  expect(activeRow()?.textContent).toBe("Work");
  expect(activeRow()?.getAttribute("aria-selected")).toBe("true");
});

test("Return on a folder enters it; the folder menu offers Open All, Rename and Delete", async () => {
  const { store } = await mount();
  await key(search(), "ArrowDown");
  await contextMenu(activeRow()!);
  expect(menuLabels()).toEqual(["Open All (2)", "Rename…", "Set Icon…", "Delete"]);
  await key(search(), "Enter");
  const work = [...store.getSnapshot().tree.nodes.values()].find((node) => node.title === "Work")!;
  expect(store.getSnapshot().folder).toBe(work.id);
});

test("a bookmark's menu has the open, edit and copy verbs; Delete removes the selection in one apply", async () => {
  const { provider } = await mount();
  await key(search(), "ArrowDown");
  await key(search(), "ArrowDown");
  const row = activeRow()!;
  expect(row.textContent).toContain("GitHub");
  await contextMenu(row);
  expect(menuLabels()).toEqual(["Open", "Open in New Tab", "Open in Background Tab", "Edit…", "Copy URL", "Delete"]);
  await key(row, "Delete");
  const applies = provider.calls.filter((call) => call.op === BookmarkOps.apply);
  expect(applies.length).toBe(1);
  expect((applies[0]!.params.ops as Array<{ op: string }>).map((op) => op.op)).toEqual(["delete"]);
});

test("the empty area offers the two adds and More adds the file steps", async () => {
  await mount();
  await contextMenu(host.querySelector<HTMLElement>(".bm-list-pane")!);
  expect(menuLabels()).toEqual(["Add Bookmark…", "Add Folder…"]);
  await act(async () => host.querySelector<HTMLButtonElement>(".bm-more")!.click());
  expect(menuLabels().slice(-3)).toEqual(["Import…", "Import from Browser…", "Export…"]);
});
