// User 2026-11-03: "we need to make sure every single theme, all the UI elements are colored
// properly". The host sends one terminal palette, its App Theme's (WebTheme.swift `terminal`, with
// its `type`), and the page copied it into both its light and its dark code theme. A fixed
// `markdown.theme` dark paper under a light App Theme then drew the light theme's dark-grey code
// on dark paper (and a light paper under a dark theme the reverse). The host's palette fills its
// own scheme; the other scheme keeps the default palette, which reads on its paper. The app's one
// highlight color stays the selection in both.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { resolveDiffViewerAppearance } from "../src/appearance";

type ThemeWindow = Window & { cmuxTheme?: { current?: unknown } };

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window, document: window.document });
});

afterEach(() => {
  delete (window as ThemeWindow).cmuxTheme;
});

function hostSends(type: "light" | "dark", background: string, foreground: string) {
  const terminal = {
    type,
    background,
    foreground,
    palette: { "4": type === "light" ? "#0969da" : "#9ccfd8" },
    fontFamily: null,
    selectionBackground: "#335577",
  };
  (window as ThemeWindow).cmuxTheme = { current: { variables: {}, colorScheme: type, scrollers: "overlay", terminal } };
}

describe("the host's terminal palette fills only its own scheme", () => {
  test("a light App Theme leaves the dark paper's code to the dark palette", () => {
    hostSends("light", "#ffffff", "#1f2328");
    const { themes } = resolveDiffViewerAppearance(undefined);
    expect(themes.light.foreground).toBe("#1f2328");
    expect(themes.light.palette).toEqual({ "4": "#0969da" });
    expect(themes.dark.foreground).toBe("#ffffff");
    expect(themes.dark.background).toBe("#000000");
    expect(themes.dark.palette).toEqual({});
    expect(themes.dark.selectionBackground).toBe("#335577");
  });

  test("a dark App Theme leaves the light paper's code to the light palette", () => {
    hostSends("dark", "#191724", "#e0def4");
    const { themes } = resolveDiffViewerAppearance(undefined);
    expect(themes.dark.foreground).toBe("#e0def4");
    expect(themes.dark.palette).toEqual({ "4": "#9ccfd8" });
    expect(themes.light.foreground).toBe("#000000");
    expect(themes.light.background).toBe("#ffffff");
    expect(themes.light.palette).toEqual({});
    expect(themes.light.selectionBackground).toBe("#335577");
  });
});
