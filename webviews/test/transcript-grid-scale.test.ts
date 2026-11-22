// gridScale runs on every transcript render. While a reply streams each render follows a DOM commit, so a
// computed-style read there is a whole-document style recalc the visible frame waits behind (a tenth of the
// focused chat's main thread in composer-typing L1). Pin that it reads the inline scale the app writes on
// <html>, reads the stylesheets only once otherwise, and still follows a scale change.
/// <reference types="bun" />
import { afterAll, beforeAll, expect, test } from "bun:test";
import { Window } from "happy-dom";

const window = new Window();
const saved: Record<string, unknown> = {};
const names = ["window", "document", "getComputedStyle"] as const;
let computedReads = 0;

beforeAll(() => {
  for (const name of names) saved[name] = (globalThis as Record<string, unknown>)[name];
  const computed = window.getComputedStyle.bind(window);
  Object.assign(globalThis, {
    window,
    document: window.document,
    getComputedStyle: (element: Element) => {
      computedReads += 1;
      return computed(element as never);
    },
  });
});

afterAll(() => {
  for (const name of names) (globalThis as Record<string, unknown>)[name] = saved[name];
  window.close();
});

test("gridScale reads the inline scale with no computed-style read", async () => {
  const { gridScale } = await import("../src/agent-session/acpmux/transcriptGrid");
  const root = window.document.documentElement;
  root.style.setProperty("--cmux-interface-scale", "1.25");
  computedReads = 0;
  for (let i = 0; i < 50; i += 1) expect(gridScale()).toBe(1.25);
  root.style.setProperty("--cmux-interface-scale", "1.5");
  expect(gridScale()).toBe(1.5);
  expect(computedReads).toBe(0);
});

test("without an inline scale the stylesheets are read once, and again on a scale event", async () => {
  const { gridScale } = await import("../src/agent-session/acpmux/transcriptGrid");
  const { INTERFACE_SCALE_EVENT } = await import("../src/ui/interfaceScale");
  const doc = window.document;
  doc.documentElement.style.removeProperty("--cmux-interface-scale");
  const style = doc.createElement("style");
  style.textContent = ":root { --cmux-interface-scale: 1.75; }";
  doc.head.appendChild(style);
  computedReads = 0;
  for (let i = 0; i < 50; i += 1) expect(gridScale()).toBe(1.75);
  expect(computedReads).toBe(1);
  style.textContent = ":root { --cmux-interface-scale: 2; }";
  window.dispatchEvent(new window.Event(INTERFACE_SCALE_EVENT));
  expect(gridScale()).toBe(2);
  expect(computedReads).toBe(2);
});
