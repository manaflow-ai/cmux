// Code takes its token colors from the terminal theme's ANSI palette, as Ghostty does (cx-wqn5):
// the agent chat, the diff viewer and the Markdown page share one scope-to-slot map, the pages
// get the palette with every host theme change (WebTheme's `terminal`), and a change recolors
// code in place, without re-registering a Shiki theme or re-rendering.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { syntaxThemes } from "../src/agent-session/acpmux/diffTheme";
import * as appearanceModule from "../src/appearance";
import { contrastBetween, SYNTAX_MIN_CONTRAST } from "../src/syntax-colors";
import { shikiThemeFromGhostty } from "../src/pierre-options";

type ThemeWindow = Window & { cmuxTheme?: { current?: unknown } };
type Appearance = Parameters<typeof appearanceModule.resolveDiffViewerAppearance>[0];

const { applyDiffViewerAppearance, resolveDiffViewerAppearance } = appearanceModule;
/** Re-applies a page's look on every host theme change (looked up so a missing one fails the test). */
const followHostTerminalTheme = (apply: (appearance: Appearance) => void): (() => void) => {
  const follow = (appearanceModule as Record<string, unknown>).followHostTerminalTheme;
  expect(typeof follow).toBe("function");
  return (follow as (apply: (appearance: Appearance) => void) => () => void)(apply);
};

/** A dark terminal theme whose every slot is a distinct, readable color. */
const night = {
  background: "#101018",
  foreground: "#e8e8f0",
  palette: Object.fromEntries(
    ["#606070", "#ff6060", "#60ff60", "#ffff60", "#6090ff", "#ff60ff", "#60ffff", "#c0c0c0"]
      .concat(["#808090", "#ff8080", "#80ff80", "#ffff80", "#80b0ff", "#ff80ff", "#80ffff", "#ffffff"])
      .map((color, slot) => [String(slot), color]),
  ),
};

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window, document: window.document });
});

function hostSends(terminal: typeof night) {
  const payload = { variables: {}, colorScheme: "dark", scrollers: "overlay", terminal };
  (window as ThemeWindow).cmuxTheme = { current: payload };
  window.dispatchEvent(new window.CustomEvent("cmux-theme", { detail: payload }));
}

function rootVariable(name: string): string {
  return document.documentElement.style.getPropertyValue(name).trim();
}

/** The variable a Shiki rule's foreground reads (`var(--x, fallback)`), or the color itself. */
function variableOf(color: string | undefined): string | undefined {
  return color?.match(/^var\((--[\w-]+)/)?.[1];
}

function ruleFor(
  theme: { tokenColors: Array<{ scope?: string | string[]; settings: { foreground?: string } }> },
  scope: string,
) {
  return theme.tokenColors.find((rule) => [rule.scope ?? []].flat().includes(scope));
}

afterEach(() => {
  delete (window as ThemeWindow).cmuxTheme;
  document.documentElement.removeAttribute("style");
});

describe("code colors come from the terminal palette", () => {
  test("a page without its own appearance uses the terminal theme the host sends", () => {
    hostSends(night);
    const resolved = resolveDiffViewerAppearance(undefined);
    expect(resolved.themes.dark.palette?.["5"]).toBe("#ff60ff");
    expect(resolved.themes.dark.background).toBe("#101018");
  });

  test("a page's keyword reads the palette's magenta and follows a theme change in place", () => {
    hostSends(night);
    const stop = followHostTerminalTheme((appearance) =>
      applyDiffViewerAppearance(resolveDiffViewerAppearance(appearance)),
    );
    const resolved = resolveDiffViewerAppearance(undefined);
    const theme = shikiThemeFromGhostty({ ...resolved.themes.dark, type: "dark" }, resolved);
    const keyword = variableOf(ruleFor(theme, "keyword")?.settings.foreground);
    expect(keyword).toBeDefined();
    expect(rootVariable(keyword!)).toBe("#ff60ff");

    // The user edits the Ghostty palette: the same rule now paints the new magenta.
    hostSends({ ...night, palette: { ...night.palette, "5": "#d070ff" } });
    expect(rootVariable(keyword!)).toBe("#d070ff");
    stop();
  });

  test("plain code text follows the terminal foreground in place", () => {
    hostSends(night);
    const stop = followHostTerminalTheme((appearance) =>
      applyDiffViewerAppearance(resolveDiffViewerAppearance(appearance)),
    );
    const resolved = resolveDiffViewerAppearance(undefined);
    const theme = shikiThemeFromGhostty({ ...resolved.themes.dark, type: "dark" }, resolved);
    const plain = variableOf(theme.tokenColors.find((rule) => rule.scope == null)?.settings.foreground);
    expect(plain).toBeDefined();
    expect(rootVariable(plain!)).toBe("#e8e8f0");
    hostSends({ ...night, foreground: "#f0e0d0" });
    expect(rootVariable(plain!)).toBe("#f0e0d0");
    stop();
  });

  test("the chat and the pages map each scope to the same palette slot", () => {
    hostSends(night);
    applyDiffViewerAppearance(resolveDiffViewerAppearance(undefined));
    const resolved = resolveDiffViewerAppearance(undefined);
    const page = shikiThemeFromGhostty({ ...resolved.themes.dark, type: "dark" }, resolved);
    const chat = syntaxThemes.dark;
    for (const scope of [
      "keyword",
      "string",
      "comment",
      "constant.numeric",
      "entity.name.function",
      "entity.name.type",
    ]) {
      const slot = variableOf(ruleFor(chat, scope)?.settings.foreground)?.match(/^--agent-ansi-(\d+)$/)?.[1];
      expect({ scope, slot }).toEqual({ scope, slot: expect.any(String) });
      const pageColor = rootVariable(variableOf(ruleFor(page, scope)?.settings.foreground) ?? "");
      expect({ scope, color: pageColor }).toEqual({ scope, color: night.palette[slot!] });
    }
  });

  test("every code color reads on a pale low-contrast theme (TokyoNight Day)", () => {
    const day = {
      background: "#e1e2e7",
      foreground: "#3760bf",
      palette: Object.fromEntries(
        ["#e9e9ed", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#6172b0"]
          .concat(["#a1a6c5", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#3760bf"])
          .map((color, slot) => [String(slot), color]),
      ),
    };
    const colors = appearanceModule.syntaxColorsFor(day, "light");
    for (const [role, color] of Object.entries(colors)) {
      const ratio = contrastBetween(color, day.background) ?? 0;
      expect({ role, readable: ratio >= SYNTAX_MIN_CONTRAST }).toEqual({ role, readable: true });
    }
  });
});
