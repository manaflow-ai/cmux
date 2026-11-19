// The Task Manager's rows render only when their own process changed: a sample (about once a
// second) that moves one process's CPU redraws that row alone, and a click that moves the
// selection redraws the two rows whose selected state flipped. Counted from React's commits
// (support/rowRenders.ts), not from the row.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import type { TaskManagerRow, TaskManagerSnapshot } from "../src/pages/task-manager/types";

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

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

// A fresh object per row each sample, as the app's JSON is.
const sample = (revision: number, n: number, busy?: number): TaskManagerSnapshot => ({
  revision,
  total: "Total",
  rows: Array.from({ length: n }, (_, index): TaskManagerRow => ({
    id: `local:${index + 1}`,
    host: "local",
    pid: index + 1,
    task: `Tab ${index}`,
    name: "zsh",
    cpu: index === busy ? 50 : 0,
    cpuText: index === busy ? "50.0%" : "0.0%",
    memoryBytes: 1_000,
    memoryText: "1 KB",
    refusal: null,
  })),
});

async function mount(n: number) {
  const { TaskManagerRoot } = await import("../src/pages/task-manager/TaskManagerPage");
  const { MockTaskManagerProvider } = await import("../src/pages/task-manager/mockProvider");
  const { TaskManagerStore } = await import("../src/pages/task-manager/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/task-manager/generated/strings.json")).default;
  const store = new TaskManagerStore(new MockTaskManagerProvider(), { snapshot: sample(1, n) });
  act(() => root?.unmount());
  rowRenders.clear();
  root = createRoot(host);
  act(() => root!.render(createElement(TaskManagerRoot, { store, strings: createStrings(table, ["en"]) })));
  return store;
}

const mouseDown = (element: Element) =>
  act(
    () =>
      void element.dispatchEvent(
        new (scope.window as Window & typeof globalThis).MouseEvent("mousedown", { bubbles: true }),
      ),
  );

for (const n of [100, 1_000]) {
  test(`a sample that changes one of ${n} processes renders one row`, async () => {
    const store = await mount(n);
    expect(rowRenders.count("Row")).toBe(n);
    rowRenders.reset();
    act(() => store.replace(sample(2, n, 7)));
    expect(rowRenders.count("Row")).toBe(1);
    expect(host.querySelector('.tm-row[data-row-id="local:8"] td:nth-child(4)')?.textContent).toBe("50.0%");
    // A sample with nothing new renders no row.
    rowRenders.reset();
    act(() => store.replace(sample(3, n, 7)));
    expect(rowRenders.count("Row")).toBe(0);
  });

  test(`selecting one of ${n} processes renders the two rows whose selection flipped`, async () => {
    const store = await mount(n);
    mouseDown(host.querySelector('.tm-row[data-row-id="local:3"]')!);
    expect(store.getState().selected).toBe("local:3");
    rowRenders.reset();
    mouseDown(host.querySelector('.tm-row[data-row-id="local:9"]')!);
    expect(store.getState().selected).toBe("local:9");
    expect(rowRenders.count("Row")).toBe(2);
    expect(host.querySelector('.tm-row[data-row-id="local:9"]')?.getAttribute("aria-selected")).toBe("true");
    expect(host.querySelector('.tm-row[data-row-id="local:3"]')?.getAttribute("aria-selected")).toBe("false");
  });
}
