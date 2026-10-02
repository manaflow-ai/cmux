import { afterAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { applyAgentTheme } from "./theme";
import type { AgentSessionTheme } from "./types";

// The root `agent-session-web:test` run has no DOM package installed, so the
// test stands in the few document members `applyAgentTheme` touches.
const properties = new Map<string, string>();
const fakeDocument = {
  documentElement: {
    dataset: {} as Record<string, string>,
    classList: { toggle: () => true },
    style: {
      colorScheme: "",
      setProperty: (name: string, value: string) => void properties.set(name, value),
      removeProperty: (name: string) => void properties.delete(name),
      getPropertyValue: (name: string) => properties.get(name) ?? "",
    },
  },
  body: { dataset: {} as Record<string, string> },
};
const globals = globalThis as Record<string, unknown>;
const saved = globals.document;
globals.document = fakeDocument;
afterAll(() => {
  globals.document = saved;
});

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
    const acpmux = css("../acpmux/styles.css");
    expect(acpmux).toMatch(/--acpmux-base:var\(--agent-accent-text/);
    expect(acpmux).toMatch(/\.acpmux-send-ready[^{]*\{[^}]*color:var\(--acpmux-base\)/);
    const shared = css("./styles.css");
    expect(shared).toMatch(/--color-token-button-foreground:\s*var\(--agent-accent-text/);
    expect(shared).toMatch(/--agent-primary-text:\s*var\(--agent-accent-text/);
  });

  // The composer and the docked session list sit on the page, which already
  // paints the theme's background; a second fill stacks with it and hides a
  // translucent window's backdrop.
  for (const selector of [".acpmux-composer", ".acpmux-sidebar"]) {
    test(`${selector} paints no background of its own`, () => {
      const escaped = selector.replace(/[.]/g, "\\.");
      const rule = css("../acpmux/styles.css").match(new RegExp(`${escaped}\\{[^}]*\\}`))?.[0] ?? "";
      expect(rule).not.toBe("");
      expect(rule).not.toMatch(/background:(?!transparent|none)/);
    });
  }

  // A translucent window's page is clear; the composer box and its edge
  // must be a tint over the page, not mixed toward the opaque base, or the
  // box is a solid block over the backdrop. On an opaque page the page is
  // the base, so nothing changes there.
  test("the composer box is a tint over the page", () => {
    const acpmux = css("../acpmux/styles.css");
    for (const name of ["--acpmux-composer-bg", "--acpmux-composer-edge"]) {
      expect(acpmux).toMatch(
        new RegExp(`${name}:color-mix\\(in srgb,var\\(--agent-text\\) \\d+%,var\\(--agent-page-bg`),
      );
    }
  });

  // Over a clear page the composer box is only a tint, so what is drawn with
  // or inside it must not borrow it: the idle Send arrow needs an opaque
  // color, the narrow-window session overlay an opaque surface, and the
  // composer's hover pills a tint rather than the menus' opaque fill.
  test("nothing in the composer borrows its translucent box color", () => {
    const acpmux = css("../acpmux/styles.css");
    const send = acpmux.match(/\.acpmux-send\{[^}]*\}/)?.[0] ?? "";
    expect(send).not.toBe("");
    expect(send).not.toMatch(/[;{]color:var\(--acpmux-composer-bg\)/);
    const overlay = acpmux.match(/\[data-sidebar=open\] \.acpmux-sidebar\{[^}]*\}/)?.[0] ?? "";
    expect(overlay).toMatch(/background:var\(--acpmux-base\)/);
    for (const hover of [
      /\.acpmux-composer-plus:hover:enabled\{[^}]*\}/,
      /\.acpmux-picker-button:hover[^{]*\{[^}]*\}/,
    ]) {
      const rule = acpmux.match(hover)?.[0] ?? "";
      expect(rule).not.toBe("");
      expect(rule).not.toMatch(/--acpmux-menu-hover/);
    }
  });
});
