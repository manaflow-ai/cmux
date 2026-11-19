// The History list past HISTORY_VIRTUAL_FROM entries mounts only the rows near its viewport
// (HistoryLines.tsx), so its 1,000 entries (PAGE_LIMIT) cost a screenful of rows to open or filter;
// the keys still reach every row, and Return opens the one they selected.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

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
  "ResizeObserver",
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
  scope.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  // A 600-pixel list: the viewport the windowed list reads its range from.
  Object.defineProperty(dom.window.HTMLElement.prototype, "offsetHeight", {
    configurable: true,
    get: () => 600,
  });
  Object.defineProperty(dom.window.HTMLElement.prototype, "offsetWidth", {
    configurable: true,
    get: () => 800,
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
const { HistoryPage } = await import("../src/pages/history/HistoryPage");
const { HISTORY_VIRTUAL_FROM } = await import("../src/pages/history/HistoryLines");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/history/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockHistoryProvider } = await import("../src/pages/history/mockProvider");
const { HistoryStore } = await import("../src/pages/history/store");
const { ACTION_RUN } = await import("../src/pages/history/types");
type HistoryEntry = import("../src/pages/history/types").HistoryEntry;

const now = Date.now();
const entries = (count: number): HistoryEntry[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `page:default:${index}`,
    kind: "page" as const,
    at_ms: now - index * 30 * 60_000,
    title: `Page ${index}`,
    url: `https://example.test/${index}`,
    detail: `example.test/${index}`,
    available: true,
  }));

async function mount(count: number) {
  const provider = new MockHistoryProvider(entries(count));
  const store = new HistoryStore(provider, { newKey: () => "k" });
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host} dir="ltr">
        <HistoryPage store={store} strings={createStrings(table, ["en"])} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  return { provider, store };
}

const rows = () => [...host.querySelectorAll<HTMLElement>(".history-row")];

async function key(element: HTMLElement, name: string) {
  await act(async () => {
    element.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  });
}

test("1,000 entries mount only a screenful of rows, under their day titles", async () => {
  await mount(1000);
  expect(host.querySelector("#history-list")?.hasAttribute("data-virtual")).toBe(true);
  const shown = rows();
  expect(shown.length).toBeGreaterThan(0);
  expect(shown.length).toBeLessThan(60);
  expect(shown[0]!.querySelector(".history-row-title")?.textContent).toBe("Page 0");
  expect(host.querySelector(".history-group-title")).not.toBeNull();
});

test("the keys reach a row far past the window, and Return opens it", async () => {
  const { provider } = await mount(1000);
  const list = host.querySelector<HTMLElement>("#history-list")!;
  for (let press = 0; press < 120; press += 1) await key(list, "ArrowDown");
  const selected = host.querySelector<HTMLElement>('.history-row[aria-selected="true"]');
  expect(selected?.querySelector(".history-row-title")?.textContent).toBe("Page 119");
  expect(rows().length).toBeLessThan(80);
  await key(list, "Enter");
  const run = provider.calls.filter((call) => call.op === ACTION_RUN).at(-1)?.params;
  expect((run as { args: { id?: string } }).args).toMatchObject({ id: "page:default:119" });
});

test("a list under the threshold keeps every row in its sections", async () => {
  await mount(HISTORY_VIRTUAL_FROM - 1);
  expect(host.querySelector("#history-list")?.hasAttribute("data-virtual")).toBe(false);
  expect(rows().length).toBe(HISTORY_VIRTUAL_FROM - 1);
  expect(host.querySelector("section.history-group")).not.toBeNull();
});
