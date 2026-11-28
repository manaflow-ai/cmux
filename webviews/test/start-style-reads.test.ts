// A chat page's start reads no computed style for the values it asks for at once: the page
// background's see-through (desktop.ts updateSeeThrough), the Interface Size the transcript places
// its gaps at (transcriptGrid.ts gridScale), the page zoom the column is sized at (chatWidth.ts
// readUIScale) and the one the host glass measures at (ui/glass/hostGlass.ts hostGlassPageZoom).
// A computed read restyles whatever is dirty first, and at the start that is every
// element of the chat's drawn copy too (chatSnapshot/paint.ts): fleet profile of
// bench/first-load-after-restart.bench.ts (6 pages, CPU 4), 434 ms of getPropertyValue with the copy
// against 108 ms without. Each still follows the host's change at runtime.
//
// Leo, 2026-11-22: "the speed i see on restarts is terminal << chromium browser <<<<<<<< our [...]
// agent pane."
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { SEE_THROUGH_ATTRIBUTE, updateSeeThrough } from "../src/pages/shared/desktop";
import { gridScale } from "../src/agent-session/acpmux/transcriptGrid";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  (["window", "document", "getComputedStyle"] as const).map((key) => [key, { had: key in scope, value: scope[key] }]),
);

/// Every computed-style read in the test's window, and the probe color the next one answers.
let reads = 0;
let drawn = "rgba(0, 0, 0, 0)";
const computed = () => {
  reads++;
  return { backgroundColor: drawn, getPropertyValue: () => "" } as unknown as CSSStyleDeclaration;
};

beforeAll(() => {
  (dom.window as unknown as { getComputedStyle: unknown }).getComputedStyle = computed;
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.getComputedStyle = computed;
});
afterAll(() => {
  for (const [key, entry] of Object.entries(saved))
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
});

const doc = () => dom.window.document;
const root = () => doc().documentElement;
const seeThrough = () => root().hasAttribute(SEE_THROUGH_ATTRIBUTE);

test("see-through: the start decides from the host's inline background, with no computed read", () => {
  reads = 0;
  root().style.removeProperty("--cmux-surface-background");
  updateSeeThrough(doc());
  expect(seeThrough()).toBe(false);

  root().style.setProperty("--cmux-surface-background", "rgba(30, 30, 30, 0.6)");
  updateSeeThrough(doc());
  expect(seeThrough()).toBe(true);
  // The same theme again (a `cmux-theme` with this background) reads nothing either.
  updateSeeThrough(doc());
  expect(seeThrough()).toBe(true);
  expect(reads).toBe(0);
});

test("see-through: a changed background is read as drawn, and read again once its transition ends", () => {
  root().style.setProperty("--cmux-surface-background", "rgba(30, 30, 30, 0.6)");
  updateSeeThrough(doc());
  reads = 0;
  // The host makes the page opaque; its color transition still draws the see-through value.
  root().style.setProperty("--cmux-surface-background", "rgba(30, 30, 30, 1)");
  drawn = "rgba(30, 30, 30, 0.6)";
  updateSeeThrough(doc());
  expect(reads).toBe(1);
  expect(seeThrough()).toBe(true);
  // WebTheme `settled`: the second `cmux-theme` once the blend ends.
  drawn = "rgba(30, 30, 30, 1)";
  updateSeeThrough(doc());
  expect(reads).toBe(2);
  expect(seeThrough()).toBe(false);
  // Settled: the same theme again reads nothing.
  const before = reads;
  updateSeeThrough(doc());
  expect(reads).toBe(before);
  expect(seeThrough()).toBe(false);
  // The host takes its theme away (the plain-browser dev loop): off, no read.
  root().style.removeProperty("--cmux-surface-background");
  updateSeeThrough(doc());
  expect(seeThrough()).toBe(false);
  expect(reads).toBe(before);
});

// With no inline value (a page no app hosts) transcriptGrid.ts reads the computed one once and keeps it
// (its computedScale); a page the host writes the scale on reads only the declaration.
test("gridScale reads the host's inline Interface Size per call, never computed", () => {
  reads = 0;
  root().style.setProperty("--cmux-interface-scale", "1");
  expect(gridScale()).toBe(1);
  root().style.setProperty("--cmux-interface-scale", "1.25");
  expect(gridScale()).toBe(1.25);
  root().style.setProperty("--cmux-interface-scale", "1.5");
  expect(gridScale()).toBe(1.5);
  root().style.setProperty("--cmux-interface-scale", "nope");
  expect(gridScale()).toBe(1);
  expect(reads).toBe(0);
  root().style.removeProperty("--cmux-interface-scale");
});

test("the column's page zoom loads with no computed read and follows the host's change", async () => {
  reads = 0;
  root().style.setProperty("--cmux-ui-scale", "1.25");
  // A module of its own (the query), so its load-time read happens here, in this window.
  const fresh = "../src/agent-session/acpmux/chatWidth.ts?start-style-reads";
  const { uiScale } = (await import(fresh)) as typeof import("../src/agent-session/acpmux/chatWidth");
  expect(uiScale()).toBe(1.25);
  root().style.setProperty("--cmux-ui-scale", "1.5");
  dom.window.dispatchEvent(new dom.window.Event("cmux-ui-scale-change"));
  expect(uiScale()).toBe(1.5);
  root().style.removeProperty("--cmux-ui-scale");
  dom.window.dispatchEvent(new dom.window.Event("cmux-ui-scale-change"));
  expect(uiScale()).toBe(1);
  expect(reads).toBe(0);
});

test("the host glass reads the page zoom from the host's inline value, never computed", async () => {
  reads = 0;
  const { hostGlassPageZoom } = await import("../src/ui/glass/hostGlass");
  root().style.removeProperty("--cmux-ui-scale");
  expect(hostGlassPageZoom(doc())).toBe(1);
  root().style.setProperty("--cmux-ui-scale", "1.25");
  expect(hostGlassPageZoom(doc())).toBe(1.25);
  root().style.removeProperty("--cmux-ui-scale");
  expect(reads).toBe(0);
});
