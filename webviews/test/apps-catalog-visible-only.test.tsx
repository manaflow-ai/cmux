// The App Store's catalog draws what is visible (the visible-only rule): at 1,000 and 10,000
// listings, read from the owner 200 at a time, Discover mounts the same cards and DOM nodes, and a
// reload that changes one listing or a one-row scroll draws again only the cards whose listing
// changed or that the scroll brought in. Before, every listing was a mounted card, and every reload
// drew each of them again: the cards were not memoized and each reload made new listing objects.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
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

/** The page's scroll area is 800 px tall; each catalog row is as tall as the page estimates. */
const VIEWPORT = 800;
const GRID_ROW = 150;
const LIST_ROW = 56;
const appsSizes = (element: HTMLElement) =>
  element.classList.contains("apps-scroll") || element.classList.contains("apps-split-list")
    ? VIEWPORT
    : element.dataset.size?.startsWith("grid")
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
