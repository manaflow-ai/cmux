// Code pages (diffs, Markdown code, the Monaco editor) select in the app's one highlight color
// (user 2026-10-28: "make sure the highlight color across everything in the app can be customized
// (and is consistent) based on the user's terminal theme"). The host sends it with every theme
// (WebTheme.swift `terminal.selectionBackground`: the terminal theme's selection, or
// `appearance.highlightColor` over it). Before, these pages selected in a fixed blue
// (#abd8ff light, #3f638b dark) whatever the theme was.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { applyDiffViewerAppearance, followHostTerminalTheme, resolveDiffViewerAppearance } from "../src/appearance";

type ThemeWindow = Window & { cmuxTheme?: { current?: unknown } };

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window, document: window.document });
});

afterEach(() => {
  delete (window as ThemeWindow).cmuxTheme;
  document.documentElement.removeAttribute("style");
});

function hostSends(selectionBackground?: string) {
  const terminal = {
    type: "dark",
    background: "#101018",
    foreground: "#e8e8f0",
    palette: {},
    fontFamily: null,
    selectionBackground,
  };
  const payload = { variables: {}, colorScheme: "dark", scrollers: "overlay", terminal };
  (window as ThemeWindow).cmuxTheme = { current: payload };
  window.dispatchEvent(new window.CustomEvent("cmux-theme", { detail: payload }));
}

const selection = (type: "light" | "dark") =>
  document.documentElement.style.getPropertyValue(`--cmux-diff-selection-bg-${type}`).trim();

describe("code pages select in the app's highlight color", () => {
  test("the host's selection color is the diff and editor selection, and follows a change in place", () => {
    hostSends("#335577");
    const stop = followHostTerminalTheme(() => applyDiffViewerAppearance(resolveDiffViewerAppearance(undefined)));
    expect(selection("dark")).toBe("#335577");
    expect(selection("light")).toBe("#335577");
    expect(resolveDiffViewerAppearance(undefined).themes.dark.selectionBackground).toBe("#335577");
    hostSends("#ff8800");
    expect(selection("dark")).toBe("#ff8800");
    stop();
  });

  test("a page's own themes still win over the host's", () => {
    hostSends("#335577");
    const resolved = resolveDiffViewerAppearance({ themes: { dark: { selectionBackground: "#123456" }, light: {} } });
    expect(resolved.themes.dark.selectionBackground).toBe("#123456");
  });
});
