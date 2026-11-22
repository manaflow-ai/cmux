// The editor's one highlighting system: Shiki, with the diff viewer's grammars (every bundled Shiki
// language, one lazy chunk each), its theme (the terminal palette, pierre-options.ts
// `shikiThemeFromGhostty`, or a Shiki theme named by `appearance.syntaxTheme`) and the user's
// languages from `<config dir>/diff/languages/` (diff-languages/pack.ts), detected by the diff
// viewer's detector (diff-languages/detect.ts). The regex engine is the diff viewer's Oniguruma
// (WebAssembly; view.ts falls back to Shiki's JavaScript engine under a CSP without
// 'wasm-unsafe-eval'). Monaco gets the grammars through @shikijs/monaco (view.ts).
import type { HighlighterCore, LanguageRegistration, ThemeRegistrationAny } from "shiki/core";
import { resolveDiffViewerAppearance, type DiffViewerAppearance } from "../../appearance";
import { createLanguageDetector, PLAIN_TEXT_LANGUAGE, type LanguageDetector } from "../../diff-languages/detect";
import { parseDiffLanguagePack, type CustomGrammar } from "../../diff-languages/pack";
import { shikiThemeFromGhostty } from "../../pierre-options";
import { syntaxThemeNames } from "./settings";

export const LIGHT_THEME = "cmux-editor-light";
export const DARK_THEME = "cmux-editor-dark";

type Loader = () => Promise<{ default: unknown }>;

export interface SyntaxDependencies {
  bundledLanguages: Record<string, Loader>;
  bundledThemes: Record<string, () => Promise<{ default: ThemeRegistrationAny }>>;
  /** Pierre's `extension -> language` map (the diff viewer's built-in detection). */
  extensionMap: Readonly<Record<string, string>>;
  createHighlighter(themes: ThemeRegistrationAny[]): Promise<HighlighterCore>;
}

/** The two themes for an appearance and the syntax theme setting. */
export async function editorThemes(
  dependencies: Pick<SyntaxDependencies, "bundledThemes">,
  syntaxTheme: unknown,
  appearance: DiffViewerAppearance | undefined,
): Promise<ThemeRegistrationAny[]> {
  const resolved = resolveDiffViewerAppearance(appearance);
  const terminal = [
    { ...shikiThemeFromGhostty({ ...resolved.themes.light, type: "light" }, resolved), name: LIGHT_THEME },
    { ...shikiThemeFromGhostty({ ...resolved.themes.dark, type: "dark" }, resolved), name: DARK_THEME },
  ] as ThemeRegistrationAny[];
  const names = syntaxThemeNames(syntaxTheme);
  const load = async (name: string, fallback: ThemeRegistrationAny, as: string) => {
    if (name === "terminal") return fallback;
    const loader = dependencies.bundledThemes[name];
    if (!loader) return fallback;
    try {
      return { ...(await loader()).default, name: as } as ThemeRegistrationAny;
    } catch {
      return fallback;
    }
  };
  return Promise.all([load(names.light, terminal[0], LIGHT_THEME), load(names.dark, terminal[1], DARK_THEME)]);
}

/** A language the editor can highlight: its Shiki id and, for user grammars, the registration. */
export interface ResolvedLanguage {
  id: string;
  user: boolean;
}

/**
 * Owns the highlighter: which languages load, which language a file gets, and the user pack. A user
 * grammar's id carries its content hash, as in the diff viewer, so an edited grammar never reuses a
 * loaded copy of the old one.
 */
export class SyntaxEngine {
  private highlighter: Promise<HighlighterCore> | null = null;
  private readonly loaded = new Map<string, Promise<boolean>>();
  private userGrammars = new Map<string, { grammar: CustomGrammar; embedded: string[] }>();
  private detector: LanguageDetector;
  warnings: string[] = [];

  constructor(
    private readonly dependencies: SyntaxDependencies,
    private themes: Promise<ThemeRegistrationAny[]>,
  ) {
    this.detector = this.makeDetector([], {});
  }

  private isBundled = (id: string) => Object.prototype.hasOwnProperty.call(this.dependencies.bundledLanguages, id);

  private makeDetector(custom: Parameters<typeof createLanguageDetector>[0]["custom"], overrides: object) {
    const user = new Set(this.userGrammars.keys());
    return createLanguageDetector({
      isLoadable: (id) => user.has(id) || this.isBundled(id),
      extensionMap: this.dependencies.extensionMap,
      custom,
      overrides,
    });
  }

  /** Installs the user languages folder (replacing the previous one). */
  installLanguages(pack: unknown): void {
    const parsed = parseDiffLanguagePack(pack);
    const warnings = [...parsed.warnings];
    const internal = new Map(
      parsed.languages.map((language) => [
        language.id.toLowerCase(),
        `cmux-user-${language.id.toLowerCase()}-${language.fingerprint}`,
      ]),
    );
    const grammars = new Map<string, { grammar: CustomGrammar; embedded: string[] }>();
    const custom = parsed.languages.map((language) => {
      const id = internal.get(language.id.toLowerCase())!;
      const embedded: string[] = [];
      for (const name of language.embeddedLanguages) {
        const resolved = internal.get(name.toLowerCase()) ?? (this.isBundled(name) ? name : null);
        if (resolved == null) warnings.push(`${language.id}: embedded language "${name}" is unknown; ignored`);
        else if (resolved !== id) embedded.push(resolved);
      }
      grammars.set(id, { grammar: language, embedded });
      return {
        id,
        aliases: [language.id, ...language.aliases],
        extensions: language.extensions,
        filenames: language.filenames,
      };
    });
    this.userGrammars = grammars;
    this.detector = this.makeDetector(custom, parsed.overrides);
    this.warnings = warnings;
  }

  /** The language of a file (a Shiki id, a user id, or `text`). */
  detect(path: string, firstLine: string | undefined): ResolvedLanguage {
    const id = this.detector({ path, firstLine });
    return { id, user: this.userGrammars.has(id) };
  }

  /** Display name of a language id (the user's id for a user grammar). */
  displayName(id: string): string {
    return this.userGrammars.get(id)?.grammar.id ?? id;
  }

  private start(): Promise<HighlighterCore> {
    this.highlighter ??= this.themes.then((themes) => this.dependencies.createHighlighter(themes));
    return this.highlighter;
  }

  /** The highlighter with `id`'s grammar loaded; false when the grammar failed or is plain text. */
  async load(id: string): Promise<boolean> {
    if (id === PLAIN_TEXT_LANGUAGE) return false;
    const existing = this.loaded.get(id);
    if (existing) return existing;
    const promise = (async () => {
      const highlighter = await this.start();
      try {
        const user = this.userGrammars.get(id);
        if (user) {
          for (const embedded of user.embedded) await this.load(embedded);
          const registration = { ...user.grammar.grammar, name: id, scopeName: user.grammar.scopeName };
          delete (registration as { aliases?: unknown }).aliases;
          await highlighter.loadLanguage(registration as unknown as LanguageRegistration);
          return true;
        }
        const loader = this.dependencies.bundledLanguages[id];
        if (!loader) return false;
        await highlighter.loadLanguage((await loader()).default as never);
        return true;
      } catch (error) {
        console.warn(`cmux editor: grammar ${id} failed`, error);
        return false;
      }
    })();
    this.loaded.set(id, promise);
    return promise;
  }

  async getHighlighter(): Promise<HighlighterCore> {
    return this.start();
  }

  /** Replaces both themes (the appearance or the syntax theme changed). */
  async setThemes(themes: Promise<ThemeRegistrationAny[]>): Promise<void> {
    this.themes = themes;
    const highlighter = this.highlighter ? await this.highlighter : null;
    if (highlighter) for (const theme of await themes) await highlighter.loadTheme(theme);
  }
}
