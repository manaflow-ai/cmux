import { afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { fileURLToPath } from "node:url";
import { act } from "react";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { IconPickerOps } from "./host";
import { mountIconPicker, type MountedPicker } from "./mount";
import { MOCK_SYMBOLS, MockIconPickerHost } from "./mockHost";

const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Element",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "Node",
  "Event",
  "KeyboardEvent",
  "MouseEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved: Record<string, unknown> = {};

// React DOM picks its input-event path when its module first evaluates; another test file may
// have loaded it before any DOM existed (no onChange for typing). Load a fresh copy once a DOM
// exists, as settings/testing.tsx does.
function freshCreateRoot(): typeof import("react-dom/client").createRoot {
  const path = fileURLToPath(new URL("./cjs/react-dom-client.development.js", import.meta.resolve("react-dom/client")));
  delete require.cache[path];
  return (require(path) as typeof import("react-dom/client")).createRoot;
}
let dom: JSDOM;
let host: MockIconPickerHost;
let picker: MountedPicker;

beforeEach(async () => {
  dom = new JSDOM("<!doctype html><html><body><main id='root'></main></body></html>", {
    url: "http://localhost/icon-picker/",
    pretendToBeVisual: true,
  });
  for (const name of GLOBALS) saved[name] = (globalThis as any)[name];
  for (const name of GLOBALS.slice(0, -1)) (globalThis as any)[name] = (dom.window as any)[name];
  (globalThis as any).getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  Object.assign(dom.window.HTMLElement.prototype, {
    attachEvent: () => undefined,
    detachEvent: () => undefined,
  });
  host = new MockIconPickerHost();
  await act(async () => {
    picker = mountIconPicker(
      dom.window.document.getElementById("root")!,
      host,
      createStrings(table, ["en"]),
      freshCreateRoot(),
    );
  });
  await act(async () => host.open({ id: "s1", canClear: true, assets: true, symbols: MOCK_SYMBOLS }));
});

afterEach(() => {
  for (const [name, value] of Object.entries(saved)) (globalThis as any)[name] = value;
});

const doc = () => dom.window.document;
const search = () => doc().querySelector<HTMLInputElement>(".icon-picker-search")!;
const press = (key: string, mods: Partial<KeyboardEventInit> = {}) =>
  act(() => {
    search().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...mods }));
  });
const type = (text: string) =>
  act(() => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(search(), text);
    search().dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
const activeLabel = () => doc().querySelector(".icon-cell[data-active] [aria-label]")?.getAttribute("aria-label");

const settle = () =>
  act(async () => {
    for (let index = 0; index < 4; index += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  });
/** Opens a shared menu by its trigger (a primary mouse press, as the shared Menu opens). */
const openMenu = async (selector: string) => {
  const trigger = doc().querySelector<HTMLElement>(selector)!;
  const event = new dom.window.Event("pointerdown", { bubbles: true, cancelable: true });
  Object.assign(event, { pointerId: 1, pointerType: "mouse", button: 0, clientX: 0, clientY: 0 });
  await act(async () => {
    trigger.dispatchEvent(event);
  });
  await settle();
};
const menuItems = () => [...doc().querySelectorAll<HTMLElement>('[role^="menuitem"]')];
const menuItem = (text: string) => menuItems().find((item) => item.textContent?.includes(text));
const choose = async (text: string) => {
  await act(async () => menuItem(text)!.click());
  await settle();
};
const headerTitles = () =>
  [...doc().querySelectorAll(".icon-grid-header")].map((header) => header.firstElementChild?.textContent);

test("opens on All Categories with search focused, large tiles and a virtualized grid", () => {
  expect(doc().activeElement).toBe(search());
  expect(search().placeholder).toBe("Search Emoji & Symbols…");
  const cells = doc().querySelectorAll(".icon-cell").length;
  expect(cells).toBeGreaterThan(0);
  expect(cells).toBeLessThan(200); // ~1900 emoji and the symbols, only the viewport mounts
  const header = doc().querySelector(".icon-grid-header")!;
  expect(header.firstElementChild?.textContent).toBe("Smileys & Emotion");
  expect(Number(header.querySelector(".icon-grid-count")?.textContent)).toBeGreaterThan(100);
  expect(doc().querySelector(".icon-category-button")?.textContent).toContain("All Categories");
});

test("search, keyboard move and Return pick an emoji", async () => {
  await type("cat");
  const first = activeLabel();
  await press("n", { ctrlKey: true });
  await press("p", { ctrlKey: true });
  expect(activeLabel()).toBe(first);
  await press("ArrowRight");
  const second = activeLabel();
  expect(second).not.toBe(first);
  await press("Enter");
  const [finish] = host.finishes() as { session: string; value: string }[];
  expect(finish.session).toBe("s1");
  expect(finish.value).toBe(picker.store.getSnapshot().layout.items[1].emoji ?? "");
});

test("search finds emoji and SF Symbols in one grid", async () => {
  await type("terminal");
  expect(headerTitles()).toContain("SF Symbols");
  const symbol = picker.store.getSnapshot().layout.items.findIndex((cell) => cell.symbol === "terminal");
  expect(symbol).toBeGreaterThanOrEqual(0);
  await act(async () => picker.store.setActive(symbol));
  await press("Enter");
  expect((host.finishes().at(-1) as { value: string }).value).toBe("terminal");
});

test("a pick goes to Frequently Used, with its count, and the tone is remembered", async () => {
  await type("thumbs up");
  await press("Enter");
  await act(async () => host.open({ id: "s2" }));
  expect(search().value).toBe("");
  const header = doc().querySelector(".icon-grid-header")!;
  expect(header.firstElementChild?.textContent).toBe("Frequently Used");
  expect(header.querySelector(".icon-grid-count")?.textContent).toBe("1");
  expect(activeLabel()).toBe("thumbs up");
  await openMenu(".icon-tone-button");
  await choose("Medium-Dark");
  expect((host.prefs as { tone: number }).tone).toBe(4);
  expect(doc().querySelector('[role="menu"]')).toBeNull();
  await type("thumbs up");
  await press("Enter");
  expect((host.finishes().at(-1) as { value: string }).value).toBe("👍🏾");
});

test("the All Categories menu lists categories with counts and narrows the grid", async () => {
  await openMenu(".icon-category-button");
  const flags = menuItem("Flags")!;
  expect(flags.querySelector(".ui-menu-shortcut")?.textContent).toMatch(/^\d+$/);
  expect(menuItem("SF Symbols")).toBeDefined();
  await choose("Flags");
  expect(doc().querySelector('[role="menu"]')).toBeNull();
  expect(headerTitles()).toEqual(["Flags"]);
  expect(doc().querySelector(".icon-category-button")?.textContent).toContain("Flags");
  expect(doc().activeElement).toBe(search());
  // Ctrl-Tab steps to the next category (SF Symbols follows the emoji groups).
  await press("Tab", { ctrlKey: true });
  expect(picker.store.getSnapshot().category).toBe("sfSymbols");
});

test("Escape clears the search, then returns to All Categories, then cancels", async () => {
  await act(async () => picker.store.setCategory("flags"));
  await type("japan");
  await press("Escape");
  expect(search().value).toBe("");
  expect(host.finishes()).toEqual([]);
  await press("Escape");
  expect(picker.store.getSnapshot().category).toBe("all");
  expect(host.finishes()).toEqual([]);
  await press("Escape");
  expect(host.finishes().at(-1)).toEqual({ session: "s1", cancel: true });
});

test("the bottom bar names the selected icon; Set Icon and Return pick it", async () => {
  await type("tada");
  expect(doc().querySelector(".icon-bar-name")?.textContent).toBe("party popper");
  expect(doc().querySelector(".icon-bar-detail")?.textContent).toBe(":tada:");
  const primary = doc().querySelector<HTMLButtonElement>(".icon-bar-primary")!;
  expect(primary.textContent).toBe("Set Icon↩");
  await act(async () => primary.click());
  expect((host.finishes().at(-1) as { value: string }).value).toBe("🎉");
});

test("Cmd-K opens Actions: Copy writes the clipboard, Remove Icon clears", async () => {
  await type("tada");
  await press("k", { metaKey: true });
  await settle();
  expect(menuItems().map((item) => item.textContent)).toEqual([
    "Set Icon↩",
    "Copy Emoji⌘C",
    "Use Image…",
    "Use SVG…",
    "Remove Icon",
  ]);
  await choose("Copy Emoji");
  expect(host.clipboard).toBe("🎉");
  expect(host.finishes()).toEqual([]);
  await press("k", { metaKey: true });
  await settle();
  await choose("Remove Icon");
  expect(host.finishes().at(-1)).toEqual({ session: "s1", clear: true });
});

test("Use Image shows the image sheet; the back button returns to the grid", async () => {
  await press("k", { metaKey: true });
  await settle();
  await choose("Use Image");
  expect(doc().querySelector(".icon-picker-heading")?.textContent).toBe("Image");
  expect(doc().querySelector(".icon-asset")).not.toBeNull();
  await act(async () => doc().querySelector<HTMLButtonElement>(".icon-picker-back")!.click());
  expect(doc().querySelector(".icon-grid-scroll")).not.toBeNull();
  expect(host.finishes()).toEqual([]);
});

test("typing while a button has focus searches", async () => {
  const back = doc().querySelector<HTMLButtonElement>(".icon-picker-back")!;
  await act(async () => back.focus());
  await act(async () => {
    back.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "c", bubbles: true, cancelable: true }));
  });
  expect(doc().activeElement).toBe(search());
});

test("Cmd-C copies the selected emoji", async () => {
  await type("tada");
  const copy = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
    clipboardData: unknown;
  };
  const data: Record<string, string> = {};
  copy.clipboardData = { setData: (type: string, value: string) => (data[type] = value) };
  await act(() => {
    search().dispatchEvent(copy);
  });
  expect(data["text/plain"]).toBe("🎉");
  expect(copy.defaultPrevented).toBe(true);
  expect(host.finishes()).toEqual([]);
});

test("a refused pick is shown and logged, and the next session clears it", async () => {
  host.refuseFinish = true;
  const logged: unknown[][] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => void logged.push(args);
  try {
    await type("cat");
    await press("Enter");
    await act(async () => undefined);
  } finally {
    console.error = original;
  }
  expect(doc().querySelector(".icon-picker-error[role=alert]")?.textContent).toBe(
    "The icon could not be applied. Try again.",
  );
  expect(logged.filter((args) => String(args[0]).startsWith("icon picker:")).length).toBe(1);
  host.refuseFinish = false;
  await act(async () => host.open({ id: "s2" }));
  expect(doc().querySelector(".icon-picker-error")).toBeNull();
});

test("no results shows the empty state", async () => {
  await type("zzzzqq");
  expect(doc().querySelector(".icon-grid-empty")?.textContent).toBe("No emoji or symbols found");
  await press("Enter");
  expect(host.calls.some((call) => call.op === IconPickerOps.finish)).toBe(false);
});

test("monochrome and hierarchical symbols are masks in the theme color; multicolor is a host image", async () => {
  await act(async () => host.open({ id: "s2", tab: "symbol", symbolStyle: "ff0000-dark" }));
  // A symbol icon opens on All Categories too (its Frequently Used row holds symbols).
  expect(picker.store.getSnapshot().category).toBe("all");
  await act(async () => picker.store.setCategory("sfSymbols"));
  await type("terminal");
  const cell = () => doc().querySelector<HTMLElement>(".icon-cell[data-active] .icon-symbol")!;
  expect(cell().style.maskImage).toContain("__symbol/terminal.png");
  // The rendering menu sits in the search row and saves the choice.
  await openMenu(".icon-mode-button");
  await choose("Hierarchical");
  expect((host.prefs as { symbolMode: string }).symbolMode).toBe("hierarchical");
  // Hierarchical is a template too: the page tints its layers with the theme foreground.
  expect(cell().style.maskImage).toContain("__symbol/hierarchical/terminal.png");
  expect(cell().style.backgroundImage).toBe("");
  // The mock catalog has no multicolor category: multicolor mode leaves these symbols monochrome.
  await act(async () => picker.store.setSymbolMode("multicolor"));
  expect(cell().style.maskImage).toContain("__symbol/terminal.png");
});
