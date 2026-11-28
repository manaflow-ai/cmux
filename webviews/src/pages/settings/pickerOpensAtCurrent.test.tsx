// A picker opens scrolled to the choice in effect, not at the top of its list (Leo, 2026-11-12, on
// the terminal theme picker: "my selected theme vs when i open up the thing. shouldn't the opened
// thing be jumped already to the proper place?"). jsdom lays nothing out, so the list gets a small
// fixed viewport and rows of a fixed height here. The scroller is the list, or the ScrollArea viewport
// inside it when the list is windowed (#46242: the theme list scrolls through the virtualizer).
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
const scrollerOf = (list: HTMLElement) => list.querySelector<HTMLElement>(".ui-combobox-viewport") ?? list;
const scrollerAround = (element: Element) => {
  const list = listOf(element);
  return list ? scrollerOf(list) : null;
};
const isScroller = (element: HTMLElement) => {
  const list = element.classList.contains("ui-combobox-list") ? element : listOf(element);
  return !!list && scrollerOf(list) === element;
};
const optionsOf = (scroller: Element) => [...scroller.querySelectorAll('[role="option"]')];
const rect = (top: number, height: number) =>
  ({ top, bottom: top + height, height, left: 0, right: 200, width: 200, x: 0, y: top, toJSON: () => ({}) }) as DOMRect;
const layout: PropertyDescriptorMap = {
  clientHeight: {
    configurable: true,
    get(this: HTMLElement) {
      return isScroller(this) ? VIEW : 0;
    },
  },
  offsetHeight: {
    configurable: true,
    get(this: HTMLElement) {
      return isScroller(this) ? VIEW : 0;
    },
  },
  scrollHeight: {
    configurable: true,
    get(this: HTMLElement) {
      return isScroller(this) ? optionsOf(this).length * ROW : 0;
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
  scrollTo: {
    configurable: true,
    value(this: HTMLElement, options?: ScrollToOptions) {
      if (options?.top !== undefined) this.scrollTop = options.top;
    },
  },
  getBoundingClientRect: {
    configurable: true,
    value(this: HTMLElement) {
      if (isScroller(this)) return rect(0, VIEW);
      const scroller = scrollerAround(this);
      if (this.getAttribute("role") !== "option" || !scroller) return rect(0, 0);
      return rect(optionsOf(scroller).indexOf(this) * ROW - scroller.scrollTop, ROW);
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
  return box.top >= 0 && box.bottom <= scrollerOf(list).clientHeight;
};

test("the theme picker opens on the selected theme, centered, when it is below the fold", async () => {
  const list = await openTerminalTheme("Tokyo Night");
  const current = list.querySelector('[aria-current="true"]')!;
  expect(current.querySelector("[data-theme-option]")?.getAttribute("data-theme-option")).toBe("Tokyo Night");
  // Use Ghostty Config, then eight themes: Tokyo Night is the ninth and last row (top 160). Centered
  // in 60 would be 140, past the end a real scroller stops at (9 rows of 20 in 60: 120), and the
  // virtualizer clamps there; the row sits wholly in view at the bottom.
  expect(scrollerOf(list).scrollTop).toBe(Math.min(8 * ROW - (VIEW - ROW) / 2, 9 * ROW - VIEW));
  expect(inView(list, current)).toBe(true);
  expect(inView(list, current)).toBe(true);
  // Only the selected row is current: the check and aria-current agree.
  expect(list.querySelectorAll('[aria-current="true"]').length).toBe(1);
});

test("a selected row already in view leaves the list at its top", async () => {
  const list = await openTerminalTheme();
  expect(list.querySelector('[aria-current="true"]')?.textContent).toContain("Ghostty");
  expect(scrollerOf(list).scrollTop).toBe(0);
});

test("typing in the search is not undone by a later jump to the selected theme", async () => {
  const list = await openTerminalTheme("Tokyo Night");
  scrollerOf(list).scrollTop = 0;
  await changeValue(document.querySelector<HTMLInputElement>(".theme-search")!, "o");
  expect(scrollerOf(list).scrollTop).toBe(0);
});

test("the font picker opens on the font in use", async () => {
  page = await renderPage({ path: "/settings/terminal", mock: { values: { "terminal.fontFamily": "SF Mono" } } });
  await click(rowElement(page.container, "terminal.fontFamily").querySelector("[data-font-picker]")!);
  const list = document.querySelector<HTMLElement>(".font-picker-panel .ui-combobox-list")!;
  const current = list.querySelector('[aria-current="true"]')!;
  expect(current.querySelector("[data-font-option]")?.getAttribute("data-font-option")).toBe("SF Mono");
  expect(scrollerOf(list).scrollTop).toBeGreaterThan(0);
  expect(inView(list, current)).toBe(true);
});
