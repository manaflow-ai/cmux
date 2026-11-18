// The Keyboard Shortcuts page draws what is visible (the visible-only rule): at 1,000 and 10,000
// actions the table mounts the same rows and DOM nodes, and a selection, a one-row scroll and a
// re-read that changes one action draw again only the rows whose data changed. Before, every action
// was a mounted row, and each selection or search keystroke drew every row again: the rows were not
// memoized, and each re-read sent new objects for every binding.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { Binding, BindingListResult } from "../src/pages/keybindings/types";
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
  "Element",
  "Node",
  "DOMRect",
  "MutationObserver",
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

/** A 600 px table viewport of 41 px rows. */
const keybindingsSizes = (element: HTMLElement) => (element.classList.contains("keys-scroll") ? 600 : 41);

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/keybindings/",
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
  installVirtualSizes(dom.window, keybindingsSizes);
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
const { KeybindingsPage } = await import("../src/pages/keybindings/KeybindingsPage");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/keybindings/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockKeybindingsProvider } = await import("../src/pages/keybindings/mockProvider");
const { KeybindingsStore } = await import("../src/pages/keybindings/store");
const { KeybindingOps } = await import("../src/pages/keybindings/types");

/** `n` actions with a key each; every re-read sends all of them as new objects, as the app does. */
class ManyActions extends MockKeybindingsProvider {
  table: Binding[];
  constructor(n: number) {
    super();
    this.table = Array.from({ length: n }, (_, index) => ({
      id: index,
      key: `cmd+k ${index}`,
      display: `⌘K ${index}`,
      command: `action.${index}`,
      title: `Action ${String(index).padStart(5, "0")}`,
      when: index % 3 ? null : "terminalFocus",
      source: "default" as const,
      conflicts: [],
    }));
  }
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op !== KeybindingOps.list) return super.call<R>(op, params);
    return {
      bindings: this.table.map((binding) => ({ ...binding, conflicts: [...binding.conflicts] })),
    } satisfies BindingListResult as R;
  }
}

async function mount(n: number) {
  const provider = new ManyActions(n);
  const store = new KeybindingsStore(provider);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(<KeybindingsPage store={store} strings={createStrings(table, ["en"])} />);
  });
  await act(async () => store.reload());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { provider, store, scroller: host.querySelector<HTMLElement>(".keys-scroll")! };
}

const rows = () => host.querySelectorAll(".keys-row").length;
const renders = mountedRowRenders(() => host.querySelectorAll(".keys-row"), "BindingRow");
const nodes = (scroller: HTMLElement) => scroller.querySelectorAll("*").length;

/** Mounted rows, DOM nodes and the row renders of one selection, one-row scroll and one-action change. */
async function measure(n: number) {
  const { provider, store, scroller } = await mount(n);
  const mounted = { rows: rows(), nodes: nodes(scroller) };

  renders.mark();
  const second = host.querySelectorAll<HTMLElement>(".keys-row")[1]!;
  await act(async () => second.click());
  const select = renders.since();

  renders.mark();
  await act(async () => {
    scroller.scrollTop += 41;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = renders.since();

  renders.mark();
  provider.table[3] = { ...provider.table[3]!, when: "editorFocus" };
  await act(async () => store.reload());
  const change = renders.since();
  return { mounted, select, scroll, change, n };
}

test("1,000 and 10,000 actions mount the same rows, and one event draws only the rows it changed", async () => {
  const small = await measure(1_000);
  act(() => root?.unmount());
  const large = await measure(10_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the viewport's rows (600 / 41) and about one viewport each side, not the table.
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
    expect(run.scroll).toBeLessThanOrEqual(2);
    // A re-read that changes one action draws that row alone.
    expect(run.change).toBeLessThanOrEqual(1);
  }
});

test("Up and Down far past the window keep the selected row mounted, in screen-reader order", async () => {
  const { scroller } = await mount(1_000);
  const search = host.querySelector<HTMLInputElement>(".keys-search")!;
  expect(dom.window.document.activeElement).toBe(search);
  for (let press = 0; press < 80; press++)
    await act(async () => {
      search.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }),
      );
    });
  const selected = () => host.querySelector<HTMLElement>('.keys-row[aria-selected="true"]');
  // The header is row 1: the 80th action is row 81 of 1,001.
  expect(selected()?.getAttribute("aria-rowindex")).toBe("81");
  expect(host.querySelector(".keys-table")?.getAttribute("aria-rowcount")).toBe("1001");
  expect(dom.window.document.activeElement).toBe(search);
  // Back at the top, the selection 80 rows down is still in the page, after the rows above it.
  await act(async () => {
    scroller.scrollTop = 0;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(selected()?.querySelector(".keys-command-title")?.textContent).toBe("Action 00079");
  const order = [...host.querySelectorAll<HTMLElement>(".keys-row")].map((row) => Number(row.dataset.index));
  expect(order).toEqual([...order].sort((a, b) => a - b));
  expect(rows()).toBeLessThanOrEqual(61);
  for (let press = 0; press < 3; press++)
    await act(async () => {
      search.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true }),
      );
    });
  expect(selected()?.getAttribute("aria-rowindex")).toBe("78");
});

test("the row whose `when` is being edited stays mounted, and keeps focus, however far the table scrolls", async () => {
  const { store, scroller } = await mount(1_000);
  const third = host.querySelectorAll<HTMLElement>(".keys-row")[2]!;
  await act(async () => third.querySelector<HTMLElement>(".keys-when")!.click());
  const input = host.querySelector<HTMLInputElement>(".keys-when-input")!;
  expect(dom.window.document.activeElement).toBe(input);
  // The selection moves on by the store (a click elsewhere would blur the editor first).
  await act(async () => {
    store.select(undefined);
    scroller.scrollTop = 41 * 600;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(input.isConnected).toBe(true);
  expect(dom.window.document.activeElement).toBe(input);
  expect(host.querySelector(".keys-row .keys-command-title")?.textContent).toBe("Action 00002");
  expect(rows()).toBeLessThanOrEqual(61);
});
