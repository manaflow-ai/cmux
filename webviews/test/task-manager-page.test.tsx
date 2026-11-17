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

test("arrowing past the visible rows reveals each newly selected row", async () => {
  const { manyRowsSnapshot } = await import("../src/pages/task-manager/mockProvider");
  const { store } = await mount(manyRowsSnapshot());
  const view = (scope.window as Window & typeof globalThis).HTMLElement.prototype;
  const original = view.scrollIntoView;
  const revealed: Array<{ row: string | null; options: unknown }> = [];
  view.scrollIntoView = function (this: HTMLElement, options?: boolean | ScrollIntoViewOptions) {
    revealed.push({ row: this.getAttribute("data-row-id"), options });
  };
  try {
    const table = host.querySelector("table")!;
    const press = (key: string) =>
      act(
        () =>
          void table.dispatchEvent(
            new (scope.window as Window & typeof globalThis).KeyboardEvent("keydown", { key, bubbles: true }),
          ),
      );
    // Well past the rows a window shows: every step reveals the row it selected.
    for (let step = 0; step < 40; step++) press("ArrowDown");
    const rows = store.getState().rows;
    expect(store.getState().selected).toBe(rows[39].id);
    expect(revealed).toHaveLength(40);
    expect(revealed.at(-1)).toEqual({ row: rows[39].id, options: { block: "nearest" } });
    expect(revealed.map((call) => call.row)).toEqual(rows.slice(0, 40).map((row) => row.id));
    press("ArrowUp");
    expect(revealed.at(-1)).toEqual({ row: rows[38].id, options: { block: "nearest" } });
    expect(host.querySelector(`.tm-row[data-row-id="${rows[38].id}"]`)?.getAttribute("aria-selected")).toBe("true");
  } finally {
    view.scrollIntoView = original;
  }
});

test("every cell carries its full text as a tooltip, and a remote id keeps its pid out of the ellipsis", async () => {
  const { longNamesSnapshot } = await import("../src/pages/task-manager/mockProvider");
  await mount(longNamesSnapshot());
  const rows = [...host.querySelectorAll(".tm-row")];
  expect(rows.length).toBeGreaterThan(0);
  for (const row of rows) {
    for (const cell of row.querySelectorAll("td")) expect(cell.getAttribute("title")).toBe(cell.textContent);
  }
  const remote = host.querySelector('.tm-row[data-row-id="devbox-eu-west-build-07:918273"]')!;
  const [task, name, pid] = remote.querySelectorAll("td");
  expect(task.getAttribute("title")).toBe("cmux daemon");
  expect(name.getAttribute("title")).toBe("cmux-tui");
  expect(pid.getAttribute("title")).toBe("devbox-eu-west-build-07:918273");
  // Only the host may ellipsize; the pid sits in its own element beside it.
  expect(pid.querySelector(".tm-remote-host")?.textContent).toBe("devbox-eu-west-build-07");
  expect(pid.querySelector(".tm-remote-pid")?.textContent).toBe(":918273");
  expect(pid.querySelector(".tm-remote-host .tm-remote-pid, .tm-remote-pid .tm-remote-host")).toBeNull();
  // A local pid is the bare number.
  const local = host.querySelector('.tm-row[data-row-id="local:6120"] td:nth-child(3)')!;
  expect(local.textContent).toBe("6120");
  expect(local.querySelector(".tm-remote-id")).toBeNull();
});
