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

  // The host's motion durations become the stylesheets' tokens; ui.animationSpeed off sends 0.
  test("sets the motion tokens in milliseconds, and a theme without them clears them", () => {
    const style = document.documentElement.style;
    applyAgentTheme({ ...theme, motion: { hover: 0.08, focus: 0.1, fadeIn: 0.18, fadeOut: 0 } });
    expect(style.getPropertyValue("--agent-motion-hover")).toBe("80ms");
    expect(style.getPropertyValue("--agent-motion-focus")).toBe("100ms");
    expect(style.getPropertyValue("--agent-motion-in")).toBe("180ms");
    expect(style.getPropertyValue("--agent-motion-out")).toBe("0ms");
    applyAgentTheme(theme);
    expect(style.getPropertyValue("--agent-motion-hover")).toBe("");
    expect(style.getPropertyValue("--agent-motion-in")).toBe("");
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
    // Send fills with the theme's text color (not the ANSI-blue highlight); its arrow is the opaque base.
    expect(acpmux).toMatch(/\.acpmux-send\{[^}]*background:var\(--agent-text\);color:var\(--acpmux-base\)/);
    expect(acpmux).not.toMatch(/\.acpmux-send[^{]*\{[^}]*--agent-highlight/);
    const shared = css("./styles.css");
    expect(shared).toMatch(/--color-token-button-foreground:\s*var\(--agent-accent-text/);
    expect(shared).toMatch(/--agent-primary-text:\s*var\(--agent-accent-text/);
  });

  // The composer sits on the page, which already paints the theme's
  // background; a second fill stacks with it and hides a translucent
  // window's backdrop.
  test(".acpmux-composer paints no background of its own", () => {
    const rule = css("../acpmux/styles.css").match(/\.acpmux-composer\{[^}]*\}/)?.[0] ?? "";
    expect(rule).not.toBe("");
    expect(rule).not.toMatch(/background:(?!transparent|none)/);
  });

  // The docked session list is the sidebar step, a tint over the page: over a
  // translucent window's clear page it stays a tint, never an opaque layer.
  test("the docked session list is only a tint over the page", () => {
    const rule = css("../acpmux/styles.css").match(/\.acpmux-sidebar\{[^}]*\}/)?.[0] ?? "";
    const background = rule.match(/[;{]background:([^;}]*)/)?.[1] ?? "";
    expect(background).toMatch(/var\(--agent-page-bg\)$/);
    expect(background).not.toMatch(/--acpmux-base|--agent-surface/);
  });

  // A translucent window's page is clear; the composer box and its edge
  // must be a tint over the page, not mixed toward the opaque base, or the
  // box is a solid block over the backdrop. On an opaque page the page is
  // the base, so nothing changes there.
  test("the composer box is a tint over the page", () => {
    const acpmux = css("../acpmux/styles.css");
    for (const name of ["--acpmux-composer-bg", "--acpmux-composer-edge", "--acpmux-composer-tray"]) {
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
    // The idle Send dims by mixing into the opaque base, never by opacity, which would let the backdrop through.
    expect(acpmux).not.toMatch(/\.acpmux-send[^{]*\{[^}]*opacity/);
    // Location controls are plain labels above the box, with no tray or chip card (composerLocation.css).
    const location = css("../acpmux/composerLocation.css");
    expect(location).toMatch(/\.acpmux-composer-context\s*\{[^}]*justify-content\s*:\s*flex-end/);
    expect(location).toMatch(/\.acpmux-location-button[^}]*background\s*:\s*none/);
    expect(location).not.toMatch(/\.acpmux-composer-context\s*\{[^}]*background\s*:/);
    const overlay = acpmux.match(/\[data-sidebar=open\] \.acpmux-sidebar\{[^}]*\}/)?.[0] ?? "";
    expect(overlay).toMatch(/background:var\(--acpmux-base\)/);
    for (const hover of [
      // The + menu is a picker, so the picker hover covers it.
      /\.acpmux-picker-button:hover[^{]*\{[^}]*\}/,
      /\.acpmux-plan:hover\{[^}]*\}/,
    ]) {
      const rule = acpmux.match(hover)?.[0] ?? "";
      expect(rule).not.toBe("");
      expect(rule).not.toMatch(/--acpmux-menu-hover/);
    }
  });
});

// From #16641: the terminal palette reaches the page as --agent-ansi-N.
const ansi = (index: number) => properties.get(`--agent-ansi-${index}`);

test("the terminal palette becomes --agent-ansi-N, and a theme without one clears it", () => {
  const palette = Array.from({ length: 16 }, (_, index) => `rgba(${index}, 0, 0, 1)`);
  applyAgentTheme({ ...theme, palette });
  expect([0, 5, 15].map(ansi)).toEqual(["rgba(0, 0, 0, 1)", "rgba(5, 0, 0, 1)", "rgba(15, 0, 0, 1)"]);
  expect(properties.get("--agent-text")).toBe("rgba(205, 214, 244, 1.0)");
  applyAgentTheme(theme);
  expect([0, 5, 15].map(ansi)).toEqual([undefined, undefined, undefined]);
});
