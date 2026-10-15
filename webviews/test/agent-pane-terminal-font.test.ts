// The agent pane draws code (inline edit diffs, the changes view, code blocks, file paths) in the
// terminal's face, as the diff, markdown and editor pages do (code-pages-terminal-font.test.ts).
// The host applies the shared web theme first (`window.cmuxTheme.apply`, its `terminal.fontFamily`)
// and then the pane's own (`applyAgentTheme`), on load and on every theme change
// (AgentPaneTheme.swift `script`); the pane's code variables follow the terminal's face.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { applyAgentTheme } from "../src/agent-session/shared/theme";
import type { AgentSessionTheme } from "../src/agent-session/shared/types";

type ThemeWindow = Window & { cmuxTheme?: { current?: unknown } };

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window, document: window.document });
});

afterEach(() => {
  delete (window as ThemeWindow).cmuxTheme;
  document.documentElement.removeAttribute("style");
});

const theme: AgentSessionTheme = {
  isDark: true,
  pageBackground: "#101018",
  surfaceBackground: "#101018",
  surfaceElevatedBackground: "#181820",
  inputBackground: "#181820",
  border: "#303040",
  borderStrong: "#404050",
  text: "#e8e8f0",
  mutedText: "#a0a0b0",
  softText: "#808090",
  accent: "#e8e8f0",
  accentSoft: "#303040",
  danger: "#e05050",
  shadow: "rgba(0, 0, 0, 0.3)",
};

/** The host's script for one theme change: the shared web theme, then the pane's. */
function hostApplies(fontFamily: string | null, codeFontFamily: string | null = fontFamily) {
  const terminal = { type: "dark", background: "#101018", foreground: "#e8e8f0", palette: {}, fontFamily };
  (window as ThemeWindow).cmuxTheme = { current: { variables: {}, colorScheme: "dark", terminal, codeFontFamily } };
  applyAgentTheme(theme);
}

const variable = (name: string) => document.documentElement.style.getPropertyValue(name).trim();

describe("the agent pane's code follows the terminal font", () => {
  test("diffs and code draw in the terminal's face, with the mono stack behind it", () => {
    hostApplies("Fira Code");
    for (const name of ["--cmux-diff-code-font-family", "--cv-code-font"]) {
      expect(variable(name).startsWith('"Fira Code",')).toBe(true);
      expect(variable(name).endsWith("monospace")).toBe(true);
    }
  });

  test("a terminal font change follows in place", () => {
    hostApplies("Fira Code");
    hostApplies("JetBrains Mono");
    expect(variable("--cmux-diff-code-font-family").startsWith('"JetBrains Mono",')).toBe(true);
    expect(variable("--cv-code-font").startsWith('"JetBrains Mono",')).toBe(true);
  });

  test("without a named terminal face the pane keeps its own mono stack", () => {
    hostApplies("Fira Code");
    hostApplies(null);
    expect(variable("--cmux-diff-code-font-family")).toBe("");
    expect(variable("--cv-code-font")).toBe("");
  });

  test("a face name with quotes stays one family", () => {
    hostApplies('My "Odd" Mono');
    expect(variable("--cv-code-font").startsWith('"My \\"Odd\\" Mono",')).toBe(true);
  });

  test("the code font setting wins over the terminal's face (appearance.fonts.code)", () => {
    hostApplies("Fira Code", "Iosevka");
    expect(variable("--cmux-diff-code-font-family").startsWith('"Iosevka",')).toBe(true);
    expect(variable("--cv-code-font").startsWith('"Iosevka",')).toBe(true);
  });
});
