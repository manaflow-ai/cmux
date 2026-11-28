// The App Store's catalog draws what is visible (the visible-only rule): at 1,000 and 10,000
// listings, read from the owner 200 at a time, Discover mounts the same cards and DOM nodes, and a
// reload that changes one listing or a one-row scroll draws again only the cards whose listing
// changed or that the scroll brought in. Before, every listing was a mounted card, and every reload
// drew each of them again: the cards were not memoized and each reload made new listing objects.
import { afterAll, afterEach, beforeAll, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";
import { until } from "./support/until";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

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
  "FocusEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

/** The page's scroll area is 800 px tall; each catalog row is as tall as the page estimates (a grid
 *  card is as tall as its row). */
const VIEWPORT = 800;
const GRID_ROW = 150;
const LIST_ROW = 56;
const gridCard = (element: HTMLElement) =>
  element.classList.contains("apps-card") && !!element.parentElement?.classList.contains("apps-catalog-space");
const appsSizes = (element: HTMLElement) =>
  element.classList.contains("apps-scroll") || element.classList.contains("apps-split-list")
    ? VIEWPORT
    : gridCard(element)
      ? GRID_ROW
      : element.dataset.size === "list"
        ? LIST_ROW
        : 0;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/apps/",
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
  installVirtualSizes(dom.window, appsSizes);
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

// The catalog's virtualizer, as the page sees it. With `hideNotify` set when the catalog mounts, the
// page gets a virtualizer without TanStack's private `notify` (as after a TanStack upgrade that
// renamed it), while TanStack's own redraws still go through it; otherwise the real one, unchanged.
const tanstack = await import("@tanstack/react-virtual");
const realUseVirtualizer = tanstack.useVirtualizer;
const notifyHidden = { hideNotify: false, notifyWrites: 0, resizes: 0 };
const hidden = new WeakMap<object, object>();
function withoutNotify<T extends object>(virtualizer: T): T {
  let proxy = hidden.get(virtualizer);
  if (!proxy) {
    const bound = new Map<PropertyKey, unknown>();
    proxy = new Proxy(virtualizer, {
      get(target, key) {
        if (key === "notify") return undefined;
        if (key === "resizeItem") notifyHidden.resizes++;
        const value = Reflect.get(target, key, target);
        if (typeof value !== "function") return value;
        if (!bound.has(key)) bound.set(key, value.bind(target));
        return bound.get(key);
      },
      has: (target, key) => key !== "notify" && Reflect.has(target, key),
      set(target, key, value) {
        if (key === "notify") notifyHidden.notifyWrites++;
        return Reflect.set(target, key, value, target);
      },
    });
    hidden.set(virtualizer, proxy);
  }
  return proxy as T;
}
await mock.module("@tanstack/react-virtual", () => ({
  ...tanstack,
  useVirtualizer: (...args: Parameters<typeof realUseVirtualizer>) => {
    const virtualizer = realUseVirtualizer(...args);
    return notifyHidden.hideNotify || hidden.has(virtualizer) ? withoutNotify(virtualizer) : virtualizer;
  },
}));

const { createRoot } = await import("react-dom/client");
const { AppsPage } = await import("../src/pages/apps/AppsPage");
const { AppsStore } = await import("../src/pages/apps/store");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const { AppsOps } = await import("../src/pages/apps/types");
const { GRID_ROW_ESTIMATE, LIST_ROW_ESTIMATE } = await import("../src/pages/apps/model");
const table = (await import("../src/pages/apps/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
import type { PageClient } from "../src/pages/shared/pageClient";
import type { WireCatalogPage, WireListing } from "../src/pages/apps/wire";

/** An owner with `n` listings, which answers `catalog.list` 200 (or `limit`) at a time. */
function owner(n: number) {
  const listings: WireListing[] = Array.from({ length: n }, (_, index) => ({
    app: `acme.tool-${index}`,
    name: `Tool ${index}`,
    summary: `Does thing ${index} for you, in the sidebar.`,
    publisher: "Acme",
    tier: "verified",
    version: "1.0.0",
    icon: null,
    categories: ["productivity"],
    hide_only: false,
    install: null,
  }));
  let pages = 0;
  const client = {
    async call<R>(op: string, params: Record<string, unknown> = {}): Promise<R> {
      if (op === AppsOps.catalogList) {
        pages++;
        const start = Number(params.cursor ?? 0);
        const end = Math.min(listings.length, start + Number(params.limit ?? 200));
        return {
          listings: listings.slice(start, end).map((listing) => ({ ...listing })),
          next_cursor: end < listings.length ? String(end) : null,
          revision: 1,
        } satisfies WireCatalogPage as R;
      }
      if (op === AppsOps.installedList) return { revision: 1, apps: [] } as R;
      if (op === AppsOps.updatesList) return { revision: 1, updates: [] } as R;
      throw new Error(`unexpected ${op}`);
    },
    async subscribe() {
      return () => {};
    },
  } as unknown as PageClient;
  return {
    client,
    listings,
    get pages() {
      return pages;
    },
  };
}

async function mount(n: number, layout: "grid" | "list" | "split" = "grid", app?: string) {
  const data = owner(n);
  const store = new AppsStore(data.client, `#/discover?layout=${layout}${app ? `&app=${app}` : ""}`);
  host = document.getElementById("root")!;
  const strings = createStrings(table, ["en"]);
  await act(async () => {
    root = createRoot(host);
    root.render(
      <UiProvider container={host}>
        <AppsPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  // The page's own start reads the catalog, page by page.
  await until(
    () => store.getSnapshot().catalog.length >= n,
    () => act(async () => {}),
  );
  const scroller = host.querySelector<HTMLElement>(".apps-scroll, .apps-split-list")!;
  return { data, store, scroller };
}

const cards = () => host.querySelectorAll(".apps-catalog-section:last-of-type .apps-card, .apps-row");
const domNodes = () => host.querySelectorAll(".apps-catalog-section:last-of-type *").length;

async function scrollBy(scroller: HTMLElement, px: number) {
  await act(async () => {
    scroller.scrollTo({ top: scroller.scrollTop + px });
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

test("the estimates the jsdom sizes follow are the page's", () => {
  expect(GRID_ROW_ESTIMATE).toBe(GRID_ROW);
  expect(LIST_ROW_ESTIMATE).toBe(LIST_ROW);
});

for (const layout of ["grid", "list"] as const) {
  test(`${layout}: mounted cards and DOM nodes are the same at 1,000 and 10,000 listings`, async () => {
    const counts: { n: number; cards: number; nodes: number; pages: number }[] = [];
    for (const n of [1_000, 10_000]) {
      const { data } = await mount(n, layout);
      counts.push({ n, cards: cards().length, nodes: domNodes(), pages: data.pages });
      act(() => root?.unmount());
      root = undefined;
    }
    const [small, large] = counts as [(typeof counts)[0], (typeof counts)[0]];
    // Every page of the catalog still loads: 200 listings a page.
    expect(small.pages).toBe(5);
    expect(large.pages).toBe(50);
    expect(small.cards).toBeGreaterThan(0);
    // One viewport of rows plus overscan, far below N.
    expect(small.cards).toBeLessThan(100);
    expect(large.cards).toBe(small.cards);
    expect(Math.abs(large.nodes - small.nodes)).toBeLessThanOrEqual(small.nodes * 0.1);
  });

  test(`${layout}: a reload that changes one listing draws only its card; a scroll step draws only what it brings in`, async () => {
    const { data, store, scroller } = await mount(10_000, layout);
    const renders = mountedRowRenders(() => cards(), layout === "grid" ? "ItemCard" : "ItemRow");
    renders.mark();
    data.listings[1] = { ...data.listings[1]!, name: "Renamed" };
    await act(async () => {
      await store.reload();
    });
    expect(host.textContent).toContain("Renamed");
    expect(renders.since()).toBe(1);

    renders.mark();
    await act(async () => {
      await store.reload();
    });
    expect(renders.since()).toBe(0);

    const step = layout === "grid" ? GRID_ROW + 14 : LIST_ROW + 2;
    const columns = layout === "grid" ? 2 : 1;
    for (let index = 0; index < 5; index++) {
      renders.mark();
      await scrollBy(scroller, step);
      expect(renders.since()).toBeLessThanOrEqual(columns);
    }
  });
}

test("the list's rows give their place among every listing", async () => {
  await mount(1_000, "list");
  const rows = [...host.querySelectorAll('[role="listitem"]')];
  expect(rows.length).toBeGreaterThan(0);
  expect(rows[0]!.getAttribute("aria-posinset")).toBe("1");
  expect(rows[0]!.getAttribute("aria-setsize")).toBe("1000");
});

test("a search finds a listing far down the catalog, and the windowed list shows it", async () => {
  const { store } = await mount(10_000);
  await act(async () => store.setQuery("Tool 9999"));
  const names = [...host.querySelectorAll(".apps-catalog-section:last-of-type .apps-name")].map(
    (name) => name.textContent,
  );
  expect(names).toEqual(["Tool 9999"]);
});

test("a focused card stays mounted, and keeps focus, when the catalog scrolls far past it", async () => {
  const { scroller } = await mount(10_000);
  const open = host.querySelector<HTMLButtonElement>(".apps-catalog-section:last-of-type .apps-card-open")!;
  await act(async () => open.focus());
  expect(document.activeElement).toBe(open);
  await scrollBy(scroller, 50 * (GRID_ROW + 14));
  expect(open.isConnected).toBe(true);
  expect(document.activeElement).toBe(open);
  expect(cards().length).toBeLessThan(100);
});

test("the split view keeps its selected row mounted however far the list scrolls", async () => {
  const { scroller } = await mount(10_000, "split", "acme.tool-3");
  expect(host.querySelector(".apps-row.selected .apps-name")?.textContent).toBe("Tool 3");
  await scrollBy(scroller, 200 * (LIST_ROW + 2));
  expect(host.querySelector(".apps-row.selected .apps-name")?.textContent).toBe("Tool 3");
  expect(cards().length).toBeLessThan(100);
});

// Tab and Shift-Tab across the window. Each card holds tab stops (open, Preview, Install; a list row
// has open and Install). The focused listing's row, the rows before and after it and the first and
// last rows stay mounted, so the browser's own Tab goes to the next listing however far the catalog
// scrolled from the focused one.
const TABBABLE = 'button:not([disabled]), input:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])';
const STEP = { grid: GRID_ROW + 14, list: LIST_ROW + 2 } as const;

/** One Tab as a browser does it (jsdom moves no focus on Tab): the next tab stop in document order
 *  takes focus, and a row out of view scrolls into view. */
async function tab(scroller: HTMLElement, layout: "grid" | "list", shift = false) {
  const stops = [...document.querySelectorAll<HTMLElement>(TABBABLE)];
  const next = stops[stops.indexOf(document.activeElement as HTMLElement) + (shift ? -1 : 1)];
  await act(async () => next?.focus());
  const listing = focusedListing();
  if (listing < 0) return;
  // Two grid columns at 800 px.
  const top = Math.floor(listing / (layout === "grid" ? 2 : 1)) * STEP[layout];
  const bottom = top + STEP[layout];
  if (top < scroller.scrollTop) await scrollBy(scroller, top - scroller.scrollTop);
  else if (bottom > scroller.scrollTop + VIEWPORT) await scrollBy(scroller, bottom - scroller.scrollTop - VIEWPORT);
}

/** The listing whose card or row holds focus, by its place in the catalog; -1 outside it. */
function focusedListing(): number {
  const app = document.activeElement?.closest<HTMLElement>(".apps-catalog-space [data-app]")?.dataset.app;
  return app ? Number(app.split("-").pop()) : -1;
}
const stopsOf = (index: number) => [
  ...host.querySelectorAll<HTMLElement>(`.apps-catalog-space [data-app="acme.tool-${index}"] button`),
];

for (const layout of ["grid", "list"] as const) {
  test(`${layout}: Tab goes through 200 listings one at a time, and Shift-Tab back`, async () => {
    const { scroller } = await mount(1_000, layout);
    await act(async () => stopsOf(0)[0]!.focus());
    const forward = [focusedListing()];
    for (let step = 0; step < 1_000 && forward.at(-1)! >= 0 && forward.at(-1)! < 199; step++) {
      await tab(scroller, layout);
      if (focusedListing() !== forward.at(-1)) forward.push(focusedListing());
    }
    expect(forward).toEqual(Array.from({ length: 200 }, (_, index) => index));
    const back = [focusedListing()];
    for (let step = 0; step < 1_000 && back.at(-1)! > 0; step++) {
      await tab(scroller, layout, true);
      if (focusedListing() !== back.at(-1)) back.push(focusedListing());
    }
    expect(back).toEqual(Array.from({ length: 200 }, (_, index) => 199 - index));
  });

  // The last listing of a grid row (two columns at 800 px), so the next one is on the next row.
  const from = 5;
  test(`${layout}: Tab from a focused listing the catalog scrolled 20,000 px away goes to the next listing`, async () => {
    const { scroller } = await mount(1_000, layout);
    await act(async () => stopsOf(from).at(-1)!.focus());
    await scrollBy(scroller, 20_000);
    await tab(scroller, layout);
    expect(focusedListing()).toBe(from + 1);
  });

  test(`${layout}: Shift-Tab from a focused listing the catalog scrolled 20,000 px away goes to the one before it`, async () => {
    const { scroller } = await mount(1_000, layout);
    await act(async () => stopsOf(from + 1)[0]!.focus());
    await scrollBy(scroller, 20_000);
    await tab(scroller, layout, true);
    expect(focusedListing()).toBe(from);
  });

  test(`${layout}: Tab from a focused listing far down, after scrolling back to the top, goes to the next listing`, async () => {
    const { scroller } = await mount(1_000, layout);
    const target = 401;
    await scrollBy(scroller, Math.floor(target / (layout === "grid" ? 2 : 1)) * STEP[layout]);
    await act(async () => stopsOf(target).at(-1)!.focus());
    await scrollBy(scroller, -scroller.scrollTop);
    await tab(scroller, layout);
    expect(focusedListing()).toBe(target + 1);
  });
}

/** A column change in jsdom: the page is `width` px wide (two columns at 800 px, three from 830), a
 *  grid row is 150 px tall at two columns and 120 at three, the catalog starts at the top of the
 *  scroll area's content (no banner height in jsdom), and the page's ResizeObservers are kept so
 *  `resize` can tell the listing it resized, as a browser does. */
async function columnChange(
  run: (page: {
    width: () => number;
    rowHeight: () => number;
    resize: (to: number) => Promise<void>;
    cardsResized: (height: number) => Promise<void>;
  }) => Promise<void>,
) {
  let width = 800;
  let grown: number | undefined;
  const rowHeight = () => grown ?? (width >= 830 ? 120 : GRID_ROW);
  const proto = dom.window.HTMLElement.prototype;
  const offsetWidth = Object.getOwnPropertyDescriptor(proto, "offsetWidth")!;
  const offsetHeight = Object.getOwnPropertyDescriptor(proto, "offsetHeight")!;
  const rect = proto.getBoundingClientRect;
  const observers: { callback: ResizeObserverCallback; targets: Set<Element> }[] = [];
  const globals = { ResizeObserver: scope.ResizeObserver, Event: scope.Event };
  Object.defineProperty(proto, "offsetWidth", { configurable: true, get: () => width });
  Object.defineProperty(proto, "offsetHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return gridCard(this) ? rowHeight() : appsSizes(this);
    },
  });
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const scroller = this.closest<HTMLElement>(".apps-scroll");
    const top = this.classList.contains("apps-catalog-space") && scroller ? -scroller.scrollTop : 0;
    return { top, left: 0, right: width, bottom: top, width, height: 0, x: 0, y: top, toJSON() {} } as DOMRect;
  };
  scope.ResizeObserver = class {
    entry: { callback: ResizeObserverCallback; targets: Set<Element> };
    constructor(callback: ResizeObserverCallback) {
      this.entry = { callback, targets: new Set() };
      observers.push(this.entry);
    }
    observe(target: Element) {
      this.entry.targets.add(target);
    }
    unobserve(target: Element) {
      this.entry.targets.delete(target);
    }
    disconnect() {
      this.entry.targets.clear();
    }
  };
  scope.Event = dom.window.Event;
  const resize = async (to: number) => {
    width = to;
    const listing = host.querySelector(".apps-discover-list")!;
    await act(async () => {
      for (const { callback, targets } of observers)
        if (targets.has(listing))
          callback(
            [{ target: listing, contentRect: { width } } as unknown as ResizeObserverEntry],
            {} as ResizeObserver,
          );
    });
  };
  // Every mounted card is now `height` px tall (its description wrapped again), and the cards'
  // observer hears it, as a browser's would: one callback for all of them.
  const cardsResized = async (height: number) => {
    grown = height;
    const listing = host.querySelector(".apps-discover-list")!;
    await act(async () => {
      for (const { callback, targets } of observers) {
        const entries = [...targets]
          .filter((target) => target !== listing)
          .map((target) => ({ target, contentRect: { height } }) as unknown as ResizeObserverEntry);
        if (entries.length > 0) callback(entries, {} as ResizeObserver);
      }
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  };
  try {
    await run({ width: () => width, rowHeight, resize, cardsResized });
  } finally {
    Object.defineProperty(proto, "offsetWidth", offsetWidth);
    Object.defineProperty(proto, "offsetHeight", offsetHeight);
    proto.getBoundingClientRect = rect;
    scope.ResizeObserver = globals.ResizeObserver;
    scope.Event = globals.Event;
  }
}

// A width that changes the grid's columns moves every listing to another row, and a row's height
// follows its cards' width. The first row in view stays where it was, and the rows not mounted are
// estimated at the new columns' height. Before, the scroll stayed where it was (other listings came
// into view) and every unmounted row kept the old columns' height.
/** The grid's layout, as a browser does it: its cards fill rows of as many columns as fit, and a
 *  spacer takes a row of its own; a gap of 14 px after each row. The listing's top in the view, and
 *  the grid's height. */
function gridLayout(scroller: HTMLElement, columns: number, rowHeight: number, index?: number) {
  const space = host.querySelector<HTMLElement>(".apps-catalog-space")!;
  let top = 0;
  let column = 0;
  for (const child of space.children as Iterable<HTMLElement>) {
    if (child.classList.contains("apps-catalog-gap")) {
      if (column > 0) top += rowHeight + 14;
      column = 0;
      top += parseFloat(child.style.height) + 14;
      continue;
    }
    if (child.dataset.app === `acme.tool-${index}`) return { top: top - scroller.scrollTop, height: NaN };
    if (++column === columns) {
      top += rowHeight + 14;
      column = 0;
    }
  }
  return { top: undefined, height: (column > 0 ? top + rowHeight + 14 : top) - 14 };
}

test("grid: a column change keeps the first listing in view where it was, and sizes the rows at the new height", async () => {
  await columnChange(async ({ width, rowHeight, resize }) => {
    const { scroller } = await mount(1_000, "grid");
    // Row 30 (listings 60 and 61) at the top of the view.
    await scrollBy(scroller, 30 * (GRID_ROW + 14));
    const layoutOf = (index?: number) => gridLayout(scroller, width() >= 830 ? 3 : 2, rowHeight(), index);
    const placeOf = (index: number) => layoutOf(index).top;
    expect(placeOf(60)).toBe(0);
    await resize(830);
    // Listing 60 begins row 20 of three columns, still at the top of the view.
    expect(placeOf(60)).toBe(0);
    // 334 rows of 120 px and the gaps between them.
    expect(layoutOf().height).toBe(334 * 120 + 333 * 14);
  });
});

// The view's top cuts the first row in view (half of it above the top): that row's first listing,
// partly in view, stays where it was across the column change, at the same negative offset, both
// ways. Before, the page held the first row starting below the top, so the listing at the top moved.
test("grid: a column change keeps a partly visible first listing at the same offset from the top", async () => {
  await columnChange(async ({ width, rowHeight, resize }) => {
    const { scroller } = await mount(1_000, "grid");
    // Row 30 (listings 60 and 61) with its top half above the view.
    await scrollBy(scroller, 30 * (GRID_ROW + 14) + GRID_ROW / 2);
    const placeOf = (index: number) => gridLayout(scroller, width() >= 830 ? 3 : 2, rowHeight(), index).top;
    expect(placeOf(60)).toBe(-GRID_ROW / 2);
    await resize(830);
    // Listing 60 begins row 20 of three columns, still half a two-column row above the top.
    expect(placeOf(60)).toBe(-GRID_ROW / 2);
    await resize(800);
    expect(placeOf(60)).toBe(-GRID_ROW / 2);
  });
});

// The catalog holds back TanStack's private `notify` across a batch of row resizes (one draw for
// them all). A TanStack without it (renamed or dropped by an upgrade) gets the rows resized one at a
// time, as before the batching: the page neither throws nor writes the field, and a column change
// followed by the cards' new heights ends as the batched page does, with the listing still in view.
test("grid: without the virtualizer's private `notify`, a column change and the cards' new heights keep the listing in view", async () => {
  const outcomes: Record<string, unknown>[] = [];
  for (const hideNotify of [false, true]) {
    Object.assign(notifyHidden, { hideNotify, notifyWrites: 0, resizes: 0 });
    try {
      await columnChange(async ({ width, rowHeight, resize, cardsResized }) => {
        const { scroller } = await mount(1_000, "grid");
        await scrollBy(scroller, 30 * (GRID_ROW + 14));
        const layoutOf = (index?: number) => gridLayout(scroller, width() >= 830 ? 3 : 2, rowHeight(), index);
        await resize(830);
        expect(layoutOf(60).top).toBe(0);
        // Each mounted card (rows above the view among them) wraps to 130 px.
        await cardsResized(130);
        const mounted = [...host.querySelectorAll<HTMLElement>(".apps-catalog-space .apps-card")];
        const places = mounted.map((card) => Number(card.getAttribute("aria-posinset")));
        expect(places).toEqual(mounted.map((card) => Number(card.dataset.app!.split("-").pop()) + 1));
        expect(places).toEqual([...places].sort((a, b) => a - b));
        expect(mounted.length).toBeLessThan(100);
        expect(host.querySelector('.apps-catalog-space [data-app="acme.tool-60"] .apps-name')?.textContent).toBe(
          "Tool 60",
        );
        // Every mounted row is at its cards' new height, every other row at least at the estimate.
        const rows = new Set(mounted.map((card) => Math.floor(Number(card.dataset.app!.split("-").pop()) / 3))).size;
        expect(layoutOf().height).toBeGreaterThanOrEqual(334 * 120 + 333 * 14 + rows * 10);
        outcomes.push({
          top: layoutOf(60).top,
          scrollTop: scroller.scrollTop,
          mounted: mounted.map((card) => card.dataset.app),
          rows,
          height: layoutOf().height,
        });
        act(() => root?.unmount());
        root = undefined;
      });
    } finally {
      notifyHidden.hideNotify = false;
    }
    if (hideNotify) {
      // The fallback ran: rows were resized, and the page never touched the missing field.
      expect(notifyHidden.resizes).toBeGreaterThan(0);
      expect(notifyHidden.notifyWrites).toBe(0);
    }
  }
  const [batched, fallback] = outcomes as [Record<string, unknown>, Record<string, unknown>];
  // The listing that was at the top of the view is still there (TanStack moved the scroll by what
  // the rows above it grew), at the same scroll, with the same cards mounted, either way.
  expect(fallback.top).toBe(0);
  const { height: fallbackHeight, ...fallbackView } = fallback;
  const { height: _batchedHeight, ...batchedView } = batched;
  expect(fallbackView).toEqual(batchedView);
  // Rows one at a time draw between rows, and a card the scroll took out of the window meanwhile
  // keeps the estimate (it is measured again when it mounts): every mounted row at 130 px and every
  // other row at 120. The batched page also keeps the size such a card reported.
  expect(fallbackHeight).toBe(334 * 120 + 333 * 14 + (fallback.rows as number) * 10);
});

// A column change moves each listing to another row and column, not to another card: each listing
// mounted before and after keeps its card element (and so its focus, hover and text selection), only
// the cards the new window brings in draw, and the cards stay in listing order with their place
// among every listing. Before, a card sat under its row's element, keyed by the row's first listing,
// so a column change mounted nearly every card again.
test("grid: a column change keeps each mounted listing's card, and draws only the cards it brings in", async () => {
  await columnChange(async ({ resize }) => {
    const { scroller } = await mount(1_000, "grid");
    await scrollBy(scroller, 30 * (GRID_ROW + 14));
    const catalogCards = () => [...host.querySelectorAll<HTMLElement>(".apps-catalog-space .apps-card")];
    const renders = mountedRowRenders(catalogCards, "ItemCard");
    for (const to of [830, 800, 830]) {
      const before = new Map(catalogCards().map((card) => [card.dataset.app!, card]));
      renders.mark();
      await resize(to);
      const after = catalogCards();
      const kept = after.filter((card) => before.has(card.dataset.app!));
      // Most of the window stays mounted across the change.
      expect(kept.length).toBeGreaterThan(before.size / 2);
      expect(kept.filter((card) => before.get(card.dataset.app!) !== card).map((card) => card.dataset.app)).toEqual([]);
      expect(renders.since()).toBe(after.length - kept.length);
      const places = after.map((card) => Number(card.getAttribute("aria-posinset")));
      expect(places).toEqual(after.map((card) => Number(card.dataset.app!.split("-").pop()) + 1));
      expect(places).toEqual([...places].sort((a, b) => a - b));
      expect(after.every((card) => card.getAttribute("aria-setsize") === "1000")).toBe(true);
    }
  });
});
