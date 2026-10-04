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
  "HTMLElement",
  "HTMLInputElement",
  "Node",
  "Event",
  "KeyboardEvent",
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
  });
  for (const name of GLOBALS) saved[name] = (globalThis as any)[name];
  for (const name of GLOBALS.slice(0, -1)) (globalThis as any)[name] = (dom.window as any)[name];
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  Object.assign(dom.window.HTMLElement.prototype, { attachEvent: () => undefined, detachEvent: () => undefined });
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

test("opens on the emoji tab with search focused and a virtualized grid", () => {
  expect(doc().activeElement).toBe(search());
  const cells = doc().querySelectorAll(".icon-cell").length;
  expect(cells).toBeGreaterThan(0);
  expect(cells).toBeLessThan(200); // ~1900 emoji, only the viewport mounts
  expect(doc().querySelector(".icon-grid-header")?.textContent).toBe("Smileys & Emotion");
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

test("a pick goes to Frequently Used and the tone is remembered", async () => {
  await type("thumbs up");
  await press("Enter");
  await act(async () => host.open({ id: "s2" }));
  expect(search().value).toBe("");
  expect(doc().querySelector(".icon-grid-header")?.textContent).toBe("Frequently Used");
  expect(activeLabel()).toBe("thumbs up");
  await act(async () => picker.store.setTone(4));
  expect((host.prefs as { tone: number }).tone).toBe(4);
  await type("thumbs up");
  await press("Enter");
  expect((host.finishes().at(-1) as { value: string }).value).toBe("👍🏾");
});

test("Ctrl-Tab reaches Symbols; Escape cancels; Remove clears", async () => {
  await press("Tab", { ctrlKey: true });
  expect(doc().querySelector('[role="tab"][aria-selected="true"]')?.textContent).toBe("Symbols");
  await type("terminal");
  expect(activeLabel()).toBe("terminal");
  await press("Enter");
  expect((host.finishes().at(-1) as { value: string }).value).toBe("terminal");
  await press("Escape");
  expect(host.finishes().at(-1)).toEqual({ session: "s1", cancel: true });
  await act(() => doc().querySelector<HTMLButtonElement>(".icon-picker-clear")!.click());
  expect(host.finishes().at(-1)).toEqual({ session: "s1", clear: true });
});

test("the detail bar shows the name and shortcode; Cmd-C copies the selected emoji", async () => {
  await type("tada");
  expect(doc().querySelector(".icon-footer-name")?.textContent).toBe("party popper");
  expect(doc().querySelector(".icon-footer-detail")?.textContent).toBe(":tada:");
  const copy = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & { clipboardData: unknown };
  const data: Record<string, string> = {};
  copy.clipboardData = { setData: (type: string, value: string) => (data[type] = value) };
  await act(() => {
    search().dispatchEvent(copy);
  });
  expect(data["text/plain"]).toBe("🎉");
  expect(copy.defaultPrevented).toBe(true);
  expect(host.finishes()).toEqual([]);
});

test("no results shows the empty state", async () => {
  await type("zzzzqq");
  expect(doc().querySelector(".icon-grid-empty")?.textContent).toBe("No emoji found");
  await press("Enter");
  expect(host.calls.some((call) => call.op === IconPickerOps.finish)).toBe(false);
});

test("unmount (the page shell's reset) empties the root and ends the session stream", async () => {
  await act(async () => picker.unmount());
  expect(doc().getElementById("root")?.childElementCount).toBe(0);
  // A later open from the host reaches no picker.
  await act(async () => host.open({ id: "s2" }));
  expect(doc().querySelector(".icon-picker")).toBeNull();
});

test("a first session (the page shell's claim context) shows from the first render", async () => {
  await act(async () => picker.unmount());
  const second = new MockIconPickerHost();
  await act(async () => {
    picker = mountIconPicker(doc().getElementById("root")!, second, createStrings(table, ["en"]), freshCreateRoot(), {
      id: "claim-1",
      tab: "symbol",
      symbols: MOCK_SYMBOLS,
    });
  });
  expect(doc().querySelector('[role="tab"][aria-selected="true"]')?.textContent).toBe("Symbols");
  expect(doc().activeElement).toBe(search());
});
