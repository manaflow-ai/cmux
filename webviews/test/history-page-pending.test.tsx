import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { HistoryEntry } from "../src/pages/history/types";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
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
  host = dom.window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

// The History page's list can come before the owner has listed everything (`pending_kinds`,
// cmux#41639): the page says so in one quiet line, and never "No history" for a list that is not complete.
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

async function render(entries?: HistoryEntry[]) {
  const [
    { createRoot },
    { HistoryPage },
    { UiProvider, languageDirection },
    { createStrings },
    tableModule,
    historyModule,
    storeModule,
  ] = await Promise.all([
    import("react-dom/client"),
    import("../src/pages/history/HistoryPage"),
    import("../src/ui/UiProvider"),
    import("../src/pages/shared/i18n"),
    import("../src/pages/history/generated/strings.json"),
    import("../src/pages/history/mockProvider"),
    import("../src/pages/history/store"),
  ]);
  const provider = entries ? new historyModule.MockHistoryProvider(entries) : new historyModule.MockHistoryProvider();
  provider.pendingKinds = ["agent"];
  const store = new storeModule.HistoryStore(provider, { newKey: () => "k" });
  const strings = createStrings(tableModule.default, ["en"]);
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host} dir={languageDirection(strings.language)}>
        <HistoryPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { provider, store, strings };
}

test("a list that is not complete shows its rows and one quiet still-loading line", async () => {
  const { provider, strings } = await render();
  expect(host.querySelectorAll(".history-row").length).toBeGreaterThan(0);
  const sign = host.querySelectorAll(".history-pending");
  expect(sign.length).toBe(1);
  expect(sign[0]?.textContent).toBe(strings.t("page.stillLoading"));
  // `output` is the status region: the line is announced, and it is not an alert.
  expect(sign[0]?.tagName).toBe("OUTPUT");
  expect(host.querySelector('[role="alert"]')).toBeNull();

  // The owner finishes: its next reply is complete (here `history-changed` brings it), and the line goes.
  provider.pendingKinds = [];
  await act(async () => {
    provider.push({ id: "page:local:new", kind: "page", at_ms: Date.now(), title: "new", available: true });
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(host.querySelector(".history-pending")).toBeNull();
  expect(host.querySelectorAll(".history-row").length).toBeGreaterThan(0);
});

test("an empty list that is not complete says still loading, never No history", async () => {
  const { strings } = await render([]);
  expect(host.querySelectorAll(".history-row").length).toBe(0);
  expect(host.querySelector(".history-empty")?.textContent).toBe(strings.t("page.stillLoading"));
  expect(host.textContent).not.toContain(strings.t("page.empty"));
});
