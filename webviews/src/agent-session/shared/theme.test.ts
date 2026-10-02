import { afterAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { applyAgentTheme } from "./theme";
import type { AgentSessionTheme } from "./types";

const dom = new JSDOM("<!doctype html><body></body>");
const globals = globalThis as Record<string, unknown>;
const saved = { document: globals.document, navigator: globals.navigator };
Object.assign(globals, { document: dom.window.document, navigator: dom.window.navigator });
afterAll(() => Object.assign(globals, saved));

const theme: AgentSessionTheme = {
  isDark: true,
  pageBackground: "rgba(30, 30, 46, 0.8)",
  surfaceBackground: "rgba(30, 30, 46, 0.8)",
  surfaceElevatedBackground: "rgba(40, 40, 56, 1.0)",
  inputBackground: "rgba(41, 42, 58, 0.8)",
  border: "rgba(205, 214, 244, 0.08)",
  borderStrong: "rgba(205, 214, 244, 0.07)",
  text: "rgba(205, 214, 244, 1.0)",
  mutedText: "rgba(160, 166, 190, 1.0)",
  softText: "rgba(130, 136, 160, 1.0)",
  accent: "rgba(205, 214, 244, 1.0)",
  accentSoft: "rgba(205, 214, 244, 0.1)",
  accentText: "rgba(30, 30, 46, 1.0)",
  danger: "rgba(243, 139, 168, 1.0)",
  shadow: "rgba(5, 5, 7, 1.0)",
};

const css = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");

describe("agent theme", () => {
  test("sets the label color for the accent", () => {
    applyAgentTheme(theme);
    expect(document.documentElement.style.getPropertyValue("--agent-accent-text")).toBe("rgba(30, 30, 46, 1.0)");
  });

  // A theme without a key must not leave the previous theme's value behind.
  test("clears a key the next theme leaves out", () => {
    applyAgentTheme(theme);
    const { accentText: _dropped, ...withoutAccentText } = theme;
    applyAgentTheme(withoutAccentText);
    expect(document.documentElement.style.getPropertyValue("--agent-accent-text")).toBe("");
  });

  // The accent is the theme's text color, so a label on it in the text color
  // (or white on a light accent) can't be read.
  test("labels on the accent use the accent label color", () => {
    expect(css("../acpmux/styles.css")).toMatch(/\.acpmux-composer button\{[^}]*color:var\(--agent-accent-text/);
    const shared = css("./styles.css");
    expect(shared).toMatch(/--color-token-button-foreground:\s*var\(--agent-accent-text/);
    expect(shared).toMatch(/--agent-primary-text:\s*var\(--agent-accent-text/);
  });
});
