// The Stashed Tabs page draws what is visible (the visible-only rule): at 1,000 and 10,000 stashed
// pages the page mounts the same rows and DOM nodes, and a focus, a one-row scroll and a reply that
// changes one member draw again only the rows whose data changed. Before, every member was a mounted
// row (`content-visibility` on the group skipped only its paint), and each render drew every row: the
// rows were inline, with new handlers each render.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { StashRecord } from "../src/pages/stash/types";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
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

/** The Stashed Tabs page: a 600 px list of 40 px group headers and 28 px rows. */
const stashSizes = (element: HTMLElement) =>
  element.classList.contains("stash-list") ? 600 : element.classList.contains("stash-group") ? 40 : 28;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/stash/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  installVirtualSizes(dom.window, stashSizes);
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
const { StashPage } = await import("../src/pages/stash/StashPage");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/stash/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockStashProvider } = await import("../src/pages/stash/mockProvider");
const { StashStore } = await import("../src/pages/stash/store");

const NOW = Date.UTC(2026, 10, 18, 12);
const PER_GROUP = 10;

/** `n` stashed pages in groups of ten. */
function stashes(n: number): StashRecord[] {
  return Array.from({ length: Math.ceil(n / PER_GROUP) }, (_, group) => ({
    id: `s${group}`,
    name: `Workspace ${group}`,
    created_at_ms: NOW - group * 60_000,
    members: Array.from({ length: Math.min(PER_GROUP, n - group * PER_GROUP) }, (_, index) => ({
      id: `m${index}`,
      kind: "tab" as const,
      url: `https://example.com/${group}/${index}`,
      title: `Page ${group}.${index}`,
    })),
  }));
}

async function mount(n: number) {
  const provider = new MockStashProvider(stashes(n));
  const store = new StashStore(provider);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host}>
        <StashPage store={store} strings={createStrings(table, ["en"])} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { provider, store, list: host.querySelector<HTMLElement>(".stash-list")! };
}

const rows = () => host.querySelectorAll(".stash-row").length;
const renders = mountedRowRenders(() => host.querySelectorAll(".stash-row"), "StashRow");
const nodes = (list: HTMLElement) => list.querySelectorAll("*").length;

/** Mounted rows, DOM nodes and the row renders of one focus, one-row scroll and one-member change. */
async function measure(n: number) {
  const { provider, store, list } = await mount(n);
  const mounted = { rows: rows(), nodes: nodes(list) };

  renders.mark();
  const second = host.querySelectorAll<HTMLElement>(".stash-row-main")[1]!;
  await act(async () => second.focus());
  const focus = renders.since();

  const rects = { calls: 0 };
  const original = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    rects.calls++;
    return original.call(this);
  };
  renders.mark();
  await act(async () => {
    list.scrollTop += 28;
    list.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = { renders: renders.since(), rects: rects.calls };
  dom.window.Element.prototype.getBoundingClientRect = original;

  renders.mark();
  const member = provider.stashes[0]!.members[3]!;
  provider.stashes[0]!.members[3] = { ...member, title: "Changed" };
  await act(async () => store.reload());
  const change = renders.since();
  return { mounted, focus, scroll, change, n };
}

test("1,000 and 10,000 stashed pages mount the same rows, and one event draws only the rows it changed", async () => {
  const small = await measure(1_000);
  act(() => root?.unmount());
  const large = await measure(10_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the viewport's rows (600 / 28) and about one viewport each side, not the list.
  for (const run of [small, large]) {
    expect(run.mounted.rows).toBeGreaterThan(10);
    expect(run.mounted.rows).toBeLessThanOrEqual(80);
  }
  expect(Math.abs(large.mounted.rows - small.mounted.rows)).toBeLessThanOrEqual(small.mounted.rows * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);

  for (const run of [small, large]) {
    // Rule 2: focusing a row draws no row.
    expect(run.focus).toBe(0);
    // One row's scroll draws only the rows it brings in; the mounted ones keep their place.
    expect(run.scroll.renders).toBeLessThanOrEqual(2);
    // A reply that changes one member draws that row alone.
    expect(run.change).toBeLessThanOrEqual(1);
  }
  // Rule 3: a scroll reads no row's layout, at any length.
  expect(large.scroll.rects).toBe(small.scroll.rects);
});

test("the focused row stays mounted far past the window, and rows carry their place for screen readers", async () => {
  const { list } = await mount(1_000);
  const first = host.querySelector<HTMLElement>(".stash-row-main")!;
  await act(async () => first.focus());
  await act(async () => {
    list.scrollTop = 20_000;
    list.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(first.isConnected).toBe(true);
  expect(dom.window.document.activeElement).toBe(first);
  expect(first.closest(".stash-row")?.getAttribute("aria-posinset")).toBe("1");
  const shown = [...host.querySelectorAll<HTMLElement>(".stash-row")].map((row) => Number(row.ariaPosInSet));
  expect(shown.at(-1)! > 500).toBe(true);
  expect(host.querySelector(".stash-row")?.getAttribute("aria-setsize")).toBe("1000");
  expect(rows()).toBeLessThanOrEqual(81);
});
