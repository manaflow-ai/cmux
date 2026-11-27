// A picker opens scrolled to the choice in effect, not at the top of its list (Leo, 2026-11-12, on
// the terminal theme picker: "my selected theme vs when i open up the thing. shouldn't the opened
// thing be jumped already to the proper place?"). jsdom lays nothing out, so the list gets a small
// fixed viewport and rows of a fixed height here; the list itself is the scroller.
import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, renderPage, rowElement } = await import("./testing");

const ROW = 20;
const VIEW = 60;
const scrollTops = new WeakMap<Element, number>();
const listOf = (element: Element) => element.closest<HTMLElement>(".ui-combobox-list");
const isList = (element: Element) => element.classList.contains("ui-combobox-list");
const optionsOf = (list: Element) => [...list.querySelectorAll('[role="option"]')];
const rect = (top: number, height: number) =>
  ({ top, bottom: top + height, height, left: 0, right: 200, width: 200, x: 0, y: top, toJSON: () => ({}) }) as DOMRect;
const layout: PropertyDescriptorMap = {
  clientHeight: {
    configurable: true,
    get(this: HTMLElement) {
      return isList(this) ? VIEW : 0;
    },
  },
  scrollHeight: {
    configurable: true,
    get(this: HTMLElement) {
      return isList(this) ? optionsOf(this).length * ROW : 0;
    },
  },
  scrollTop: {
    configurable: true,
    get(this: HTMLElement) {
      return scrollTops.get(this) ?? 0;
    },
    set(this: HTMLElement, value: number) {
      scrollTops.set(this, Math.max(0, value));
    },
  },
  getBoundingClientRect: {
    configurable: true,
    value(this: HTMLElement) {
      if (isList(this)) return rect(0, VIEW);
      const list = listOf(this);
      if (this.getAttribute("role") !== "option" || !list) return rect(0, 0);
      return rect(optionsOf(list).indexOf(this) * ROW - list.scrollTop, ROW);
    },
  },
};

let page: Rendered | null = null;
beforeEach(() => Object.defineProperties(HTMLElement.prototype, layout));
afterEach(() => {
  page?.unmount();
  page = null;
  for (const key of Object.keys(layout)) delete (HTMLElement.prototype as unknown as Record<string, unknown>)[key];
});

const themeList = () => document.querySelector<HTMLElement>(".theme-popover .ui-combobox-list")!;
const openTerminalTheme = async (theme?: string) => {
  page = await renderPage({ path: "/settings/theme", mock: theme ? { values: { "appearance.theme": theme } } : {} });
  await click(page.container.querySelector<HTMLElement>('[data-theme-row="single"] [data-theme-picker]')!);
  return themeList();
};
const inView = (list: HTMLElement, row: Element) => {
  const box = row.getBoundingClientRect();
  return box.top >= 0 && box.bottom <= list.clientHeight;
};

test("the theme picker opens on the selected theme, centered, when it is below the fold", async () => {
  const list = await openTerminalTheme("Tokyo Night");
  const current = list.querySelector('[aria-current="true"]')!;
  expect(current.querySelector("[data-theme-option]")?.getAttribute("data-theme-option")).toBe("Tokyo Night");
  // Use Ghostty Config, then eight themes: Tokyo Night is the ninth row (top 160), centered in 60.
  expect(list.scrollTop).toBe(8 * ROW - (VIEW - ROW) / 2);
  expect(inView(list, current)).toBe(true);
  // Only the selected row is current: the check and aria-current agree.
  expect(list.querySelectorAll('[aria-current="true"]').length).toBe(1);
});

test("a selected row already in view leaves the list at its top", async () => {
  const list = await openTerminalTheme();
  expect(list.querySelector('[aria-current="true"]')?.textContent).toContain("Ghostty");
  expect(list.scrollTop).toBe(0);
});

test("typing in the search is not undone by a later jump to the selected theme", async () => {
  const list = await openTerminalTheme("Tokyo Night");
  list.scrollTop = 0;
  await changeValue(document.querySelector<HTMLInputElement>(".theme-search")!, "o");
  expect(list.scrollTop).toBe(0);
});

test("the font picker opens on the font in use", async () => {
  page = await renderPage({ path: "/settings/terminal", mock: { values: { "terminal.fontFamily": "SF Mono" } } });
  await click(rowElement(page.container, "terminal.fontFamily").querySelector("[data-font-picker]")!);
  const list = document.querySelector<HTMLElement>(".font-picker-panel .ui-combobox-list")!;
  const current = list.querySelector('[aria-current="true"]')!;
  expect(current.querySelector("[data-font-option]")?.getAttribute("data-font-option")).toBe("SF Mono");
  expect(list.scrollTop).toBeGreaterThan(0);
  expect(inView(list, current)).toBe(true);
});
