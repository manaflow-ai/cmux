// The Bookmarks list's rows render only when their own data changes (under VirtualList): one
// bookmark another writer changed renders its one row; a selection change renders the row it left
// and the row it reached; a scroll step renders only the rows that enter the window (and again as
// each one's icon lands); a re-render of
// the page with the same data renders none. Also how many rows are in the DOM at 1,000 and 10,000
// bookmarks (jsdom, an 800 px viewport).
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, afterEach, beforeAll, expect, test, jest } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
let saved: Array<readonly [string, boolean, unknown]> = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
const VIEWPORT = 800;

beforeAll(() => {
  // One fake clock for the whole file: the store's replies, the virtualizer's scroll-end reset and
  // the icon asks run when `advance` moves it, never on the wall clock.
  jest.useFakeTimers();
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/bookmarks/",
    pretendToBeVisual: true,
  });
  const { window } = dom;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  window.HTMLElement.prototype.getBoundingClientRect = () =>
    ({
      x: 0,
      y: 0,
      top: 0,
      left: 0,
      right: 600,
      bottom: VIEWPORT,
      width: 600,
      height: VIEWPORT,
      toJSON() {},
    }) as DOMRect;
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => VIEWPORT });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });
  const offsets = new WeakMap<object, number>();
  Object.defineProperty(window.HTMLElement.prototype, "scrollTop", {
    configurable: true,
    get(this: object) {
      return offsets.get(this) ?? 0;
    },
    set(this: object, value: number) {
      offsets.set(this, value);
    },
  });
  window.HTMLElement.prototype.scrollIntoView = () => undefined;
  // The virtualizer sets its timers on the element's window: they run on the same fake clock.
  Object.assign(window, {
    setTimeout: (callback: () => void, ms?: number) => setTimeout(callback, ms),
    clearTimeout: (handle: Parameters<typeof clearTimeout>[0]) => clearTimeout(handle),
  });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    HTMLInputElement: window.HTMLInputElement,
    Element: window.Element,
    Node: window.Node,
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(Date.now()), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { scope });
});

const { BookmarksPage } = await import("../src/pages/bookmarks/BookmarksPage");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/bookmarks/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockBookmarksProvider, longBookmarks } = await import("../src/pages/bookmarks/mockProvider");
const { BookmarksStore } = await import("../src/pages/bookmarks/store");
type Bookmark = import("../src/pages/bookmarks/types").Bookmark;

/** Moves the fake clock `ms` forward in 10 ms steps, each in its own act(), so each step's
 * timers, the replies they unblock and the renders they cause all land before the next. */
async function advance(ms: number) {
  for (let step = 0; step < ms; step += 10) await act(async () => void jest.advanceTimersByTime(10));
}

async function mount(count = 2_000) {
  const provider = new MockBookmarksProvider(longBookmarks(count));
  const store = new BookmarksStore(provider, { newKey: () => "k" });
  const strings = createStrings(table, ["en"]);
  const page = () => (
    <UiProvider container={host} dir="ltr">
      <BookmarksPage store={store} strings={strings} />
    </UiProvider>
  );
  root = createRoot(host);
  await act(async () => {
    root!.render(page());
  });
  await act(async () => {
    await store.start();
    store.showFolder("bm_long");
  });
  // The rows drawn ask for their icons; let those land.
  await advance(50);
  return { provider, store, rerender: () => act(async () => root!.render(page())) };
}

/** Runs `change` and lets the store, the virtualizer and its scroll-end timer settle, then reads. */
async function counted(change: () => unknown): Promise<number> {
  rowRenders.reset();
  await act(async () => {
    await change();
  });
  await advance(200);
  return rowRenders.count("BookmarkRow");
}

const shownRows = () => new Set([...host.querySelectorAll<HTMLElement>(".bm-row")].map((row) => row.dataset.bookmark!));

test("a bookmark another writer renamed renders its one row", async () => {
  const { provider } = await mount();
  expect(shownRows().has("bm_long_3")).toBe(true);
  const renders = await counted(async () => {
    const nodes = provider["nodes"] as Bookmark[];
    const at = nodes.findIndex((node) => node.id === "bm_long_3");
    nodes[at] = { ...nodes[at]!, title: "Renamed elsewhere" };
    provider.emitChanged();
  });
  expect(host.querySelector('[data-bookmark="bm_long_3"]')?.textContent).toContain("Renamed elsewhere");
  expect(renders).toBe(1);
});

test("while searching, a bookmark another writer renamed renders its one result row", async () => {
  const { provider, store } = await mount();
  await act(async () => {
    store.setText("saved page");
  });
  await advance(50);
  expect(store.getSnapshot().results?.length).toBeGreaterThan(0);
  expect(shownRows().has("bm_long_3")).toBe(true);
  const renders = await counted(async () => {
    const nodes = provider["nodes"] as Bookmark[];
    const at = nodes.findIndex((node) => node.id === "bm_long_3");
    nodes[at] = { ...nodes[at]!, title: "Saved page 4, renamed elsewhere" };
    provider.emitChanged();
  });
  expect(host.querySelector('[data-bookmark="bm_long_3"]')?.textContent).toContain("renamed elsewhere");
  expect(renders).toBe(1);
});

test("a selection change renders the row it left and the row it reached", async () => {
  const { store } = await mount();
  await act(async () => store.select("bm_long_2"));
  expect(await counted(() => store.select("bm_long_5"))).toBe(2);
  // Shift extends the range: the rows it adds render, the rest do not.
  expect(await counted(() => store.select("bm_long_7", "range"))).toBe(3);
});

test("one scroll step renders only the rows that enter the window", async () => {
  const { store } = await mount();
  const scroller = host.querySelector<HTMLElement>(".bm-list")!;
  const before = shownRows();
  const icons = () => Object.keys(store.getSnapshot().icons).length;
  const iconsBefore = icons();
  const renders = await counted(() => {
    scroller.scrollTop = 28;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
  });
  const entered = [...shownRows()].filter((id) => !before.has(id));
  expect(entered.length).toBeGreaterThan(0);
  // An entering row draws once, asks for its icon as it draws, and draws again when the icon lands
  // (its own data); the rows already in the window do not draw.
  expect(icons() - iconsBefore).toBe(entered.length);
  expect(renders).toBe(entered.length * 2);
});

test("a re-render of the page with the same data renders no row", async () => {
  const { rerender } = await mount();
  rowRenders.reset();
  await rerender();
  expect(rowRenders.count("BookmarkRow")).toBe(0);
});

test("rows in the DOM stay the window's at 1,000 and 10,000 bookmarks", async () => {
  const report: Record<number, { rows: number; nodes: number }> = {};
  for (const count of [1_000, 10_000]) {
    await mount(count);
    report[count] = {
      rows: host.querySelectorAll(".bm-row").length,
      nodes: host.querySelectorAll("*").length,
    };
    act(() => root?.unmount());
    root = undefined;
  }
  console.log("bookmarks list mounted (jsdom, 800 px):", JSON.stringify(report));
  expect(report[10_000]!.rows).toBe(report[1_000]!.rows);
  expect(report[1_000]!.rows).toBeLessThan(60);
});
