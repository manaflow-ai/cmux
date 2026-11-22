// Code block colors for the markdown editor: Shiki with the diff viewer's terminal-palette theme
// (pierre-options.ts `shikiThemeFromGhostty`, syntax-colors.ts), so code reads the same in a diff and
// in a markdown file. Grammars load lazily, one chunk per language (the same chunks the diff viewer
// uses). The JavaScript regex engine needs no WebAssembly, so the page runs under the strict PageCSP.
import type { HighlighterCore, ThemeRegistrationAny } from "shiki/core";
import { resolveDiffViewerAppearance, type DiffViewerAppearance } from "../../appearance";
import { shikiThemeFromGhostty } from "../../pierre-options";
import type { CodeToken } from "./editor";

const LIGHT = "cmux-markdown-light";
const DARK = "cmux-markdown-dark";

/** Shiki's language id for a fence info string (`ts`, `shell`, `TypeScript` ...), or null. */
export async function languageId(language: string): Promise<string | null> {
  const { bundledLanguages, bundledLanguagesAlias } = await import("shiki/langs");
  const name = language.trim().toLowerCase().split(/[\s{]/)[0];
  if (!name) return null;
  if (name in bundledLanguages) return name;
  const alias = (bundledLanguagesAlias as Record<string, unknown>)[name];
  return alias ? name : null;
}

/** The two themes for an appearance: the terminal theme's light and dark palettes. */
export function markdownThemes(appearance?: DiffViewerAppearance): ThemeRegistrationAny[] {
  const resolved = resolveDiffViewerAppearance(appearance);
  return [
    { ...shikiThemeFromGhostty({ ...resolved.themes.light, type: "light" }, resolved), name: LIGHT },
    { ...shikiThemeFromGhostty({ ...resolved.themes.dark, type: "dark" }, resolved), name: DARK },
  ] as ThemeRegistrationAny[];
}

/**
 * The code themes for the `markdown.code.theme` setting: `"terminal"` uses the terminal palette
 * (`markdownThemes`), any other name a bundled Shiki theme (loaded lazily, one chunk each). An
 * unknown name falls back to the terminal palette.
 */
export async function codeThemes(
  names: { light: string; dark: string },
  appearance?: DiffViewerAppearance,
): Promise<ThemeRegistrationAny[]> {
  const terminal = markdownThemes(appearance);
  const load = async (name: string, fallback: ThemeRegistrationAny, as: string): Promise<ThemeRegistrationAny> => {
    if (name === "terminal") return fallback;
    const { bundledThemes } = await import("shiki/themes");
    const loader = (bundledThemes as Record<string, () => Promise<{ default: ThemeRegistrationAny }>>)[name];
    if (!loader) return fallback;
    try {
      return { ...(await loader()).default, name: as };
    } catch {
      return fallback;
    }
  };
  return Promise.all([load(names.light, terminal[0], LIGHT), load(names.dark, terminal[1], DARK)]);
}

/**
 * The highlighter the editor calls synchronously: tokens for a loaded grammar, else null and a
 * grammar load that calls `refresh` when done. Tokens style both schemes through CSS variables
 * (`--md-tok-light`, `--md-tok-dark`); styles.css picks one by `prefers-color-scheme`.
 */
export class CodeHighlighter {
  private highlighter: HighlighterCore | null = null;
  private starting: Promise<HighlighterCore> | null = null;
  private readonly loaded = new Set<string>();
  private readonly failed = new Set<string>();
  private readonly pending = new Map<string, Promise<void>>();
  private readonly cache = new Map<string, CodeToken[]>();

  constructor(private themes: ThemeRegistrationAny[] | Promise<ThemeRegistrationAny[]>) {}

  private start(): Promise<HighlighterCore> {
    this.starting ??= (async () => {
      const [{ createHighlighterCore }, { createJavaScriptRegexEngine }] = await Promise.all([
        import("shiki/core"),
        import("shiki/engine/javascript"),
      ]);
      const highlighter = await createHighlighterCore({
        themes: await this.themes,
        langs: [],
        engine: createJavaScriptRegexEngine({ forgiving: true }),
      });
      this.highlighter = highlighter;
      return highlighter;
    })();
    return this.starting;
  }

  /** Replaces the themes (the host's appearance changed). Callers refresh their decorations. */
  async setThemes(themes: ThemeRegistrationAny[] | Promise<ThemeRegistrationAny[]>): Promise<void> {
    this.themes = themes;
    const resolved = await themes;
    const highlighter = this.highlighter;
    if (highlighter) for (const theme of resolved) await highlighter.loadTheme(theme);
    this.cache.clear();
  }

  tokens(code: string, language: string, refresh: () => void): CodeToken[] | null {
    const name = language.trim().toLowerCase().split(/[\s{]/)[0];
    if (!name || this.failed.has(name)) return [];
    if (!this.highlighter || !this.loaded.has(name)) {
      this.load(name).then(refresh, () => undefined);
      return null;
    }
    const key = `${name}\u0000${code}`;
    const cached = this.cache.get(key);
    if (cached) return cached;
    const tokens: CodeToken[] = [];
    try {
      const lines = this.highlighter.codeToTokens(code, {
        lang: name,
        themes: { light: LIGHT, dark: DARK },
        defaultColor: false,
      }).tokens;
      for (const line of lines) {
        for (const token of line) {
          const style = token.htmlStyle;
          if (!style) continue;
          const light = style["--shiki-light"];
          const dark = style["--shiki-dark"];
          const parts: string[] = [];
          if (light) parts.push(`--md-tok-light:${light}`);
          if (dark) parts.push(`--md-tok-dark:${dark}`);
          const fontStyle = style["--shiki-light-font-style"] ?? style["font-style"];
          if (fontStyle) parts.push(`font-style:${fontStyle}`);
          const fontWeight = style["--shiki-light-font-weight"] ?? style["font-weight"];
          if (fontWeight) parts.push(`font-weight:${fontWeight}`);
          if (parts.length)
            tokens.push({ from: token.offset, to: token.offset + token.content.length, style: parts.join(";") });
        }
      }
    } catch {
      return [];
    }
    if (this.cache.size > 500) this.cache.clear();
    this.cache.set(key, tokens);
    return tokens;
  }

  private load(name: string): Promise<void> {
    const existing = this.pending.get(name);
    if (existing) return existing;
    const promise = (async () => {
      const highlighter = await this.start();
      const id = await languageId(name);
      if (!id) {
        this.failed.add(name);
        return;
      }
      const { bundledLanguages, bundledLanguagesAlias } = await import("shiki/langs");
      const loader =
        (bundledLanguages as Record<string, () => Promise<{ default: unknown }>>)[id] ??
        (bundledLanguagesAlias as Record<string, () => Promise<{ default: unknown }>>)[id];
      try {
        await highlighter.loadLanguage((await loader()).default as never);
        // An alias (`ts`) highlights under its own name once its grammar is loaded.
        this.loaded.add(name);
      } catch {
        this.failed.add(name);
      }
    })();
    this.pending.set(name, promise);
    return promise;
  }
}
