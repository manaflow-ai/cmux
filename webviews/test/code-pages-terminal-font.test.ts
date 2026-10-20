// Code on the diff, markdown and editor pages draws in the terminal's face, as editorFont and
// appearance.ts say: the host sends it with every theme (WebTheme.swift `terminal.fontFamily`,
// cmux.json's `terminal.fontFamily` else the Ghostty config's). No cmux NEXT host ever filled the
// pages' own `appearance.fontFamily`, so code drew in Menlo whatever the terminal used.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { applyDiffViewerAppearance, followHostTerminalTheme, resolveDiffViewerAppearance } from "../src/appearance";
import { EDITOR_DEFAULTS, monacoOptions } from "../src/pages/editor/settings";

type ThemeWindow = Window & { cmuxTheme?: { current?: unknown } };

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window, document: window.document });
});

afterEach(() => {
  delete (window as ThemeWindow).cmuxTheme;
  document.documentElement.removeAttribute("style");
});

function hostSends(fontFamily: string | null) {
  const terminal = { type: "dark", background: "#101018", foreground: "#e8e8f0", palette: {}, fontFamily };
  const payload = { variables: {}, colorScheme: "dark", scrollers: "overlay", terminal };
  (window as ThemeWindow).cmuxTheme = { current: payload };
  window.dispatchEvent(new window.CustomEvent("cmux-theme", { detail: payload }));
}

const codeFamily = () => document.documentElement.style.getPropertyValue("--cmux-diff-code-font-family").trim();
const editorFamily = () =>
  monacoOptions(EDITOR_DEFAULTS, undefined, { readOnly: false, large: false, ariaLabel: "code" }).fontFamily as string;

describe("code pages follow the terminal font", () => {
  test("the diff and markdown code font is the terminal's, and follows a change in place", () => {
    hostSends("Fira Code");
    const stop = followHostTerminalTheme(() => applyDiffViewerAppearance(resolveDiffViewerAppearance(undefined)));
    expect(codeFamily().startsWith('"Fira Code",')).toBe(true);
    hostSends("JetBrains Mono");
    expect(codeFamily().startsWith('"JetBrains Mono",')).toBe(true);
    stop();
  });

  test("the code editor's font is the terminal's", () => {
    hostSends("Fira Code");
    expect(editorFamily().startsWith('"Fira Code",')).toBe(true);
  });

  test("without a named terminal face the pages keep their own defaults", () => {
    hostSends(null);
    applyDiffViewerAppearance(resolveDiffViewerAppearance(undefined));
    expect(codeFamily().startsWith('"Menlo",')).toBe(true);
    expect(editorFamily().startsWith("ui-monospace")).toBe(true);
  });

  test("a page's own appearance still wins over the terminal's", () => {
    hostSends("Fira Code");
    applyDiffViewerAppearance(resolveDiffViewerAppearance({ fontFamily: "Iosevka" }));
    expect(codeFamily().startsWith('"Iosevka",')).toBe(true);
  });
});
