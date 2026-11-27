// The Task Manager table (webviews/src/pages/task-manager/TaskManagerPage.tsx) windows its rows from
// WINDOW_FROM processes: it draws the rows near the viewport (jsdom, a 700 px scroll box) and keeps the
// whole scroll height in two spacer rows, every drawn row says its place (aria-rowindex), and the
// arrow keys still reach a row that was not drawn. Below WINDOW_FROM every row is drawn, as before.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
let saved: Array<readonly [string, boolean, unknown]> = [];
let root: Root | undefined;
let host: HTMLElement;
const VIEWPORT = 700;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  // No layout in jsdom: the table's scroll box is VIEWPORT tall, the size the virtualizer reads.
  for (const side of ["offsetHeight", "clientHeight"] as const) {
    Object.defineProperty(window.HTMLElement.prototype, side, {
      configurable: true,
      get(this: HTMLElement) {
        return this.classList.contains("tm-table-scroll") ? VIEWPORT : 0;
      },
    });
  }
  // The scroll height a browser gives the 2,000 rows, so a scroll to a late row is not clamped.
  Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("tm-table-scroll") ? 100_000 : 0;
    },
  });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", {
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains("tm-table-scroll") ? 900 : 0;
    },
  });
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

function rows(count: number) {
  return Array.from({ length: count }, (_, index) => ({
    id: `local:${1000 + index}`,
    host: "local",
    pid: 1000 + index,
    task: `Tab ${index}`,
    name: "zsh",
    cpu: 1,
    cpuText: "1.0%",
    memoryBytes: 1024,
    memoryText: "1 KB",
    refusal: null,
  }));
}

async function mount(count: number, selected?: string) {
  const { createRoot } = await import("react-dom/client");
  const { TaskManagerRoot } = await import("../src/pages/task-manager/TaskManagerPage");
  const { TaskManagerStore } = await import("../src/pages/task-manager/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/task-manager/generated/strings.json")).default;
  const strings = createStrings(table, ["en"]);
  const store = new TaskManagerStore(null, { snapshot: { revision: 1, rows: rows(count), total: "" }, selected });
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(createElement(TaskManagerRoot, { store, strings })));
  return { store };
}

const spacerHeights = () =>
  [...host.querySelectorAll<HTMLElement>(".tm-spacer td")].map((cell) => parseFloat(cell.style.height));

test("below WINDOW_FROM every row is drawn and no spacer", async () => {
  const { WINDOW_FROM } = await import("../src/pages/task-manager/TaskManagerPage");
  await mount(WINDOW_FROM - 1);
  expect(host.querySelectorAll(".tm-row").length).toBe(WINDOW_FROM - 1);
  expect(host.querySelectorAll(".tm-spacer").length).toBe(0);
  expect(host.querySelector(".tm-row")?.hasAttribute("aria-rowindex")).toBe(false);
});

test("a long table draws the rows near the viewport and keeps the whole height", async () => {
  await mount(2000);
  const drawn = [...host.querySelectorAll<HTMLElement>(".tm-row")];
  expect(drawn.length).toBeGreaterThan(VIEWPORT / 29);
  expect(drawn.length).toBeLessThan(100);
  expect(drawn[0]?.dataset.rowId).toBe("local:1000");
  expect(drawn[0]?.getAttribute("aria-rowindex")).toBe("2");
  expect(host.querySelector("table")?.getAttribute("aria-rowcount")).toBe("2001");
  // The rows not drawn keep their room below the drawn ones (none above at the top).
  const [after] = spacerHeights();
  expect(after).toBe((2000 - drawn.length) * 29);
});

test("an arrow key reaches the next row when it was not drawn", async () => {
  const { store } = await mount(2000, "local:2500");
  const scroller = host.querySelector<HTMLElement>(".tm-table-scroll")!;
  const scrolledTo: number[] = [];
  scroller.scrollTo = ((options: ScrollToOptions) => void scrolledTo.push(options.top ?? 0)) as never;
  const table = host.querySelector("table")!;
  expect(host.querySelector('.tm-row[data-row-id="local:2501"]')).toBeNull();
  act(() => {
    table.dispatchEvent(
      new (scope.window as Window & typeof globalThis).KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }),
    );
  });
  expect(store.getState().selected).toBe("local:2501");
  // The row's place below the header, less the header the scroll padding keeps it under.
  expect(scrolledTo.at(-1)).toBeGreaterThan(1400 * 29);
});
