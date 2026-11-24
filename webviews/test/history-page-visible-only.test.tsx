// The History page draws what is visible (the visible-only rule): at 1,000 and 10,000 entries the
// page mounts the same rows and DOM nodes, a selection, a one-row scroll and a reply that changes
// one entry draw again only the rows whose data changed, and a scroll reads no row's layout. Before,
// every entry was a mounted row (content-visibility skipped only their paint), and each selection
// drew every row again: the rows were not memoized and took new handlers each render.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { HistoryListResult } from "../src/pages/history/types";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { historySizes, installVirtualSizes } from "./support/virtualSizes";

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
    url: "http://localhost/history/",
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
  installVirtualSizes(dom.window, historySizes);
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
const { HistoryPage } = await import("../src/pages/history/HistoryPage");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/history/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockHistoryProvider } = await import("../src/pages/history/mockProvider");
const { HistoryStore } = await import("../src/pages/history/store");
const { HistoryOps } = await import("../src/pages/history/types");

const NOW = Date.UTC(2026, 10, 18, 12);

/** `n` entries over a few days; every reply sends all of them, past the page's own limit. */
class ManyEntries extends MockHistoryProvider {
  constructor(n: number) {
    super(
      Array.from({ length: n }, (_, index) => ({
        id: `page:local:${index}`,
        kind: "page" as const,
        at_ms: NOW - index * 60_000,
        title: `Page ${index}`,
        detail: `https://example.com/${index}`,
        url: `https://example.com/${index}`,
        available: true,
      })),
      () => NOW,
    );
  }
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op !== HistoryOps.list) return super.call<R>(op, params);
    return { entries: this.entries.map((entry) => ({ ...entry })), revision: 1 } satisfies HistoryListResult as R;
  }
}

async function mount(n: number) {
  const provider = new ManyEntries(n);
  const store = new HistoryStore(provider, { newKey: () => "k" });
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host}>
        <HistoryPage store={store} strings={createStrings(table, ["en"])} now={() => NOW} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { provider, store, list: host.querySelector<HTMLElement>("#history-list")! };
}

const rows = () => host.querySelectorAll(".history-row").length;
const renders = mountedRowRenders(() => host.querySelectorAll(".history-row"), "HistoryRow");
const nodes = (list: HTMLElement) => list.querySelectorAll("*").length;

/** Mounted rows, DOM nodes and the row renders of one selection, one-row scroll and one-entry change. */
async function measure(n: number) {
  const { provider, store, list } = await mount(n);
  const mounted = { rows: rows(), nodes: nodes(list) };

  renders.mark();
  const second = host.querySelectorAll<HTMLElement>(".history-row")[1]!;
  await act(async () => second.click());
  const select = renders.since();

  const rects = { calls: 0 };
  const original = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    rects.calls++;
    return original.call(this);
  };
  renders.mark();
  await act(async () => {
    list.scrollTop += 36;
    list.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = { renders: renders.since(), rects: rects.calls };
  dom.window.Element.prototype.getBoundingClientRect = original;

  renders.mark();
  provider.entries[3] = { ...provider.entries[3]!, title: "Changed" };
  await act(async () => store.reload());
  const change = renders.since();
  return { mounted, select, scroll, change, n };
}

test("1,000 and 10,000 entries mount the same rows, and one event draws only the rows it changed", async () => {
  const small = await measure(1_000);
  act(() => root?.unmount());
  const large = await measure(10_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the viewport's rows (600 / 36) and about one viewport each side, not the list.
  for (const run of [small, large]) {
    expect(run.mounted.rows).toBeGreaterThan(10);
    expect(run.mounted.rows).toBeLessThanOrEqual(60);
  }
  expect(Math.abs(large.mounted.rows - small.mounted.rows)).toBeLessThanOrEqual(small.mounted.rows * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);

  for (const run of [small, large]) {
    // Rule 2: a selection draws the row it leaves and the row it takes (none was selected: one).
    expect(run.select).toBeLessThanOrEqual(2);
    // One row's scroll draws only the rows it brings in; the mounted ones keep their place.
    expect(run.scroll.renders).toBeLessThanOrEqual(2);
    // A reply that changes one entry draws that row alone.
    expect(run.change).toBeLessThanOrEqual(1);
  }
  // Rule 3: a scroll reads no row's layout, at any length.
  expect(large.scroll.rects).toBe(small.scroll.rects);
});

test("Up and Down far past the window keep the focused row and reach the selected one", async () => {
  await mount(1_000);
  const first = host.querySelector<HTMLElement>(".history-row")!;
  await act(async () => first.focus());
  for (let press = 0; press < 40; press++)
    await act(async () => {
      dom.window.document.activeElement!.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }),
      );
    });
  // TanStack scrolls to the selection in a frame of its own: yield frames until it has, at most 60.
  const list = host.querySelector<HTMLElement>("#history-list")!;
  for (let frame = 0; frame < 60 && list.scrollTop <= 600; frame++)
    await act(async () => new Promise((resolve) => requestAnimationFrame(() => resolve(undefined))));
  expect(list.scrollTop).toBeGreaterThan(600);
  // The row that had focus is still in the page and still has it; the selection is 40 rows on.
  expect(first.isConnected).toBe(true);
  expect(dom.window.document.activeElement).toBe(first);
  const selected = host.querySelector<HTMLElement>('.history-row[aria-selected="true"]');
  expect(selected?.getAttribute("aria-posinset")).toBe("40");
  expect(rows()).toBeLessThanOrEqual(60);
});
