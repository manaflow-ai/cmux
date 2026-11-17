// The transcript's interface scale (transcriptGrid.ts gridScale) is read on every layout pass, in the
// middle of a commit that just changed the DOM. A computed-style read there forces a style recalc:
// 11 ms of a prewarmed spare's adopt task at 10 turns (first-load-after-restart MODE=reopen-spare
// PROFILE=1, getPropertyValue). These hold:
// - the App's token, written inline on <html> (DesignSettings.interfaceScaleScript), is read with no
//   computed-style read at all;
// - with no inline token the computed value is read once, not once per pass, and read again after the
//   App's `cmux-ui-scale-change`.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let computedReads = 0;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><style>:root { --cmux-interface-scale: 1.25; }</style>", {
    url: "https://cmux.test/",
  });
  const real = dom.window.getComputedStyle.bind(dom.window);
  dom.window.getComputedStyle = ((element: Element, pseudo?: string | null) => {
    computedReads += 1;
    return real(element, pseudo);
  }) as typeof dom.window.getComputedStyle;
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    getComputedStyle: dom.window.getComputedStyle,
  })) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
});

afterAll(() => {
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
  dom.window.close();
});

test("the App's inline scale token is read with no computed-style read", async () => {
  const { gridScale } = await import("../src/agent-session/acpmux/transcriptGrid");
  const root = dom.window.document.documentElement;
  root.style.setProperty("--cmux-interface-scale", "1.5");
  computedReads = 0;
  for (let pass = 0; pass < 20; pass += 1) expect(gridScale()).toBe(1.5);
  expect(computedReads, "computed-style reads for 20 layout passes").toBe(0);
  root.style.setProperty("--cmux-interface-scale", "0.875");
  expect(gridScale(), "a new inline token is read at once").toBe(0.875);
  expect(computedReads).toBe(0);
  root.style.removeProperty("--cmux-interface-scale");
});

test("with no inline token the computed scale is read once, and again after the App's scale change", async () => {
  const { gridScale } = await import("../src/agent-session/acpmux/transcriptGrid");
  const root = dom.window.document.documentElement;
  root.style.removeProperty("--cmux-interface-scale");
  dom.window.dispatchEvent(new dom.window.Event("cmux-ui-scale-change"));
  computedReads = 0;
  for (let pass = 0; pass < 20; pass += 1) expect(gridScale()).toBe(1.25);
  expect(computedReads, "computed-style reads for 20 layout passes").toBe(1);
  dom.window.document.querySelector("style")!.textContent = ":root { --cmux-interface-scale: 2; }";
  dom.window.dispatchEvent(new dom.window.Event("cmux-ui-scale-change"));
  expect(gridScale(), "the scale after the App's change").toBe(2);
  expect(computedReads).toBe(2);
});
