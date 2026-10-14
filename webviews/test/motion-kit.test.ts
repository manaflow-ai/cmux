// Two things the agent pane and pages share for calm motion (cx-sya4n):
// - The native Static status indicators setting (or Reduce Motion) reaches the page through the
//   theme: applyAgentTheme sets `data-status-indicators`, which the stylesheets stop loops under.
// - The shared late-content kit (src/ui/motion.ts): content that arrives late settles in with a
//   short fade and a few pixels of rise, a list staggers its first few rows only, and under Reduce
//   Motion the reveal is a plain fade with no movement and no stagger (small and local, Leo 10-14).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><html><body></body></html>");
  Object.assign(scope, { window, document: window.document });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const theme = {
  isDark: false,
  pageBackground: "#fff",
  surfaceBackground: "#fff",
  surfaceElevatedBackground: "#fff",
  inputBackground: "#fff",
  border: "#ddd",
  borderStrong: "#ccc",
  text: "#000",
  mutedText: "#666",
  softText: "#999",
  accent: "#000",
  accentSoft: "#eee",
  danger: "#c00",
  shadow: "#0003",
};

test("the theme's status indicators look reaches the root, and a theme without it clears it", async () => {
  const { applyAgentTheme } = await import("../src/agent-session/shared/theme");
  const root = document.documentElement;
  applyAgentTheme({ ...theme, statusIndicators: "static" });
  expect(root.dataset.statusIndicators).toBe("static");
  applyAgentTheme({ ...theme, statusIndicators: "animated" });
  expect(root.dataset.statusIndicators).toBe("animated");
  applyAgentTheme(theme);
  expect(root.dataset.statusIndicators).toBeUndefined();
});

test("a reveal fades in and rises a few pixels; under Reduce Motion it only fades", async () => {
  const { revealKeyframes } = await import("../src/ui/motion");
  const moving = revealKeyframes({ reduced: false });
  expect(moving[0]).toMatchObject({ opacity: 0 });
  const rise = /translateY\((\d+(?:\.\d+)?)px\)/.exec(String(moving[0].transform));
  expect(Number(rise?.[1])).toBeGreaterThanOrEqual(2);
  expect(Number(rise?.[1])).toBeLessThanOrEqual(4);
  const reduced = revealKeyframes({ reduced: true });
  expect(reduced.every((frame) => frame.transform === undefined)).toBe(true);
  expect(reduced[0]).toMatchObject({ opacity: 0 });
});

test("a stagger is a few short steps, capped, and nothing under Reduce Motion", async () => {
  const { stagger, STAGGER_STEP_MS, STAGGER_ITEMS } = await import("../src/ui/motion");
  expect(stagger(0, { reduced: false })).toBe(0);
  expect(stagger(1, { reduced: false })).toBe(STAGGER_STEP_MS);
  expect(STAGGER_STEP_MS).toBeLessThanOrEqual(25);
  expect(STAGGER_ITEMS).toBeLessThanOrEqual(4);
  expect(stagger(40, { reduced: false })).toBe(stagger(STAGGER_ITEMS - 1, { reduced: false }));
  expect(stagger(40, { reduced: false })).toBeLessThanOrEqual(100);
  for (const index of [0, 1, 3, 40]) expect(stagger(index, { reduced: true })).toBe(0);
});
