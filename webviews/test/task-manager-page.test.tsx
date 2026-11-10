// The Task Manager page (webviews/src/pages/task-manager/TaskManagerPage.tsx) drawn from the store's
// state: the five columns in their strings, a header click sorts and marks the column, the empty
// page says it is reading, a row's mouse-down selects it, and Kill Process is off for a row the
// policy refuses (its reason the tooltip) and does nothing on a click page script made.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
let saved: Array<readonly [string, boolean, unknown]> = [];
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function mount(snapshot?: unknown, selected?: string) {
  const { createRoot } = await import("react-dom/client");
  const { TaskManagerRoot } = await import("../src/pages/task-manager/TaskManagerPage");
  const { MockTaskManagerProvider } = await import("../src/pages/task-manager/mockProvider");
  const { TaskManagerStore } = await import("../src/pages/task-manager/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/task-manager/generated/strings.json")).default;
  const strings = createStrings(table, ["en"]);
  const provider = new MockTaskManagerProvider();
  const store = new TaskManagerStore(provider, { snapshot: snapshot as never, selected });
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(createElement(TaskManagerRoot, { store, strings })));
  return { store, provider, strings };
}

const click = (element: Element, type = "click") =>
  act(
    () =>
      void element.dispatchEvent(new (scope.window as Window & typeof globalThis).MouseEvent(type, { bubbles: true })),
  );

test("the empty page shows its columns and says it is reading processes", async () => {
  const { strings } = await mount();
  const headers = [...host.querySelectorAll("th")].map((cell) => cell.textContent);
  expect(headers).toEqual(["Task", "Process", "PID", "CPU", "Memory"]);
  expect(host.querySelector(".tm-empty")?.textContent).toBe(strings.t("taskManager.empty"));
  expect(host.querySelector(".tm-footer button")?.hasAttribute("disabled")).toBe(true);
});

test("a header click sorts by that column and marks it; a second click flips it", async () => {
  const { normalSnapshot } = await import("../src/pages/task-manager/mockProvider");
  await mount(normalSnapshot());
  const memory = host.querySelector('th[data-column="memory"]')!;
  expect(memory.getAttribute("aria-sort")).toBe("none");
  click(memory.querySelector("button")!);
  expect(memory.getAttribute("aria-sort")).toBe("ascending");
  expect(host.querySelector(".tm-row")?.getAttribute("data-row-id")).toBe("local:733");
  click(memory.querySelector("button")!);
  expect(memory.getAttribute("aria-sort")).toBe("descending");
  expect(host.querySelector(".tm-row")?.getAttribute("data-row-id")).toBe("local:501");
  expect(host.querySelector(".tm-total")?.textContent).toBe("Total: CPU 37.2% · Memory 1.08 GB");
});

test("a row's mouse-down selects it; Kill Process is off for a refused row and ignores script clicks", async () => {
  const { normalSnapshot } = await import("../src/pages/task-manager/mockProvider");
  const { provider, store } = await mount(normalSnapshot(), "local:501");
  const kill = host.querySelector<HTMLButtonElement>(".tm-footer button")!;
  expect(kill.hasAttribute("disabled")).toBe(true);
  expect(kill.getAttribute("title")).toContain("cmux itself");
  click(host.querySelector('.tm-row[data-row-id="local:734"]')!, "mousedown");
  expect(store.getState().selected).toBe("local:734");
  expect(host.querySelector('.tm-row[data-row-id="local:734"]')?.getAttribute("aria-selected")).toBe("true");
  expect(kill.hasAttribute("disabled")).toBe(false);
  click(kill);
  expect(provider.calls.map((call) => call.op)).toEqual(["cmux.task_manager.select"]);
});
