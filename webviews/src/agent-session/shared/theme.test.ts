import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { applyAgentTheme } from "./theme";
import type { AgentSessionTheme } from "./types";

const dom = new JSDOM("<!doctype html>");
const globals = globalThis as Record<string, unknown>;
const saved = { document: globals.document, navigator: globals.navigator };
Object.assign(globals, { document: dom.window.document, navigator: dom.window.navigator });
afterAll(() => Object.assign(globals, saved));

const base: AgentSessionTheme = { isDark: true, pageBackground: "#1e1e2e", surfaceBackground: "#1e1e2e", surfaceElevatedBackground: "#28283a", inputBackground: "#25253a", border: "#333", borderStrong: "#444", text: "#cdd6f4", mutedText: "#a6adc8", softText: "#7f849c", accent: "#cdd6f4", accentSoft: "#585b70", danger: "#f38ba8", shadow: "#000" };
const ansi = (index: number) => document.documentElement.style.getPropertyValue(`--agent-ansi-${index}`);

test("the terminal palette becomes --agent-ansi-N, and a theme without one clears it", () => {
  const palette = Array.from({ length: 16 }, (_, index) => `rgba(${index}, 0, 0, 1)`);
  applyAgentTheme({ ...base, palette });
  expect([0, 5, 15].map(ansi)).toEqual(["rgba(0, 0, 0, 1)", "rgba(5, 0, 0, 1)", "rgba(15, 0, 0, 1)"]);
  applyAgentTheme(base);
  expect([0, 5, 15].map(ansi)).toEqual(["", "", ""]);
});
