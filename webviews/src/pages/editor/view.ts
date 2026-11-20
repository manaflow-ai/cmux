// The Monaco side of the editor page, loaded lazily (main.tsx imports this module only when a file
// opens), so Monaco never reaches the diff or markdown pages' first load. It holds one editor and
// one model at a time and implements `CodeView` for the store.
//
// Monaco is the core API (`editor.api`) plus every editor contribution (`features/register.all`):
// no Monarch tokenizers and no language services (TypeScript, JSON, CSS, HTML workers). Tokens come
// from Shiki through @shikijs/monaco (syntax.ts owns the grammars); the editor worker is a module
// worker the build emits next to this chunk (`chunks/editor-worker.mjs`). Language configurations
// (comments, brackets, auto-closing, indentation rules) come from Monaco's own language definitions,
// loaded per language; languages Monaco has no definition for get a generic one.
import * as monaco from "monaco-editor/editor/editor.api.js";
import "monaco-editor/features/register.all.js";
import { shikiToMonaco, textmateThemeToMonacoTheme } from "@shikijs/monaco";
import { bundledLanguages, bundledLanguagesInfo } from "shiki/langs";
import { bundledThemes } from "shiki/themes";
import { createHighlighterCore } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import { createOnigurumaEngine } from "shiki/engine/oniguruma";
import { EXTENSION_TO_FILE_FORMAT } from "cmux:pierre-filetypes";
import { hostTerminalTheme, type DiffViewerAppearance } from "../../appearance";
import { PLAIN_TEXT_LANGUAGE } from "../../diff-languages/detect";
import { editorAction, isEditorAction, MONACO_QUICK_COMMAND, type EditorCommand, type RevealPosition } from "./keys";
import { keybindingRules } from "./vscodeKeys";
import { installNativeEditorMenu } from "./nativeEditorMenu";
import type { CodeView, EditorDocument } from "./store";
import { MATCH_LIMIT, type FindRange, type FindTarget } from "./editorFind";
import { DARK_THEME, LIGHT_THEME, SyntaxEngine, editorThemes } from "./syntax";
import { analyzeText, LineEndings, lineEndingLabel } from "./textCodec";
import {
  MONACO_THEME_VARIABLES,
  isLargeFile,
  modelOptions,
  monacoOptions,
  settingsForLanguage,
  type EditorSettings,
} from "./settings";
import { cssColorToHex } from "./colors";
import { markScrolling, onScrollerStyleChange, scrollerStyle } from "../../scrollers";

declare global {
  // Monaco reads its worker factory from here.
  var MonacoEnvironment: monaco.Environment | undefined;
}

// `src/pages/editor/editor.worker.ts` is an entry of the webviews-app build, emitted as
// `chunks/editor-worker.mjs` next to this chunk; the dev server maps the same URL to the source.
const EDITOR_WORKER_URL = new URL(/* @vite-ignore */ "./editor-worker.mjs", import.meta.url);
globalThis.MonacoEnvironment = {
  getWorker: (_moduleId: string, label: string) => new Worker(EDITOR_WORKER_URL, { type: "module", name: label }),
};

type ConfModule = { conf?: monaco.languages.LanguageConfiguration };
// Monaco's language definitions, one lazy chunk each. Only `conf` is used; the Monarch tokenizer
// beside it is never registered.
const definitionModules = import.meta.glob<ConfModule>([
  "../../../node_modules/monaco-editor/esm/vs/languages/definitions/*/*.js",
  "!**/register.js",
  "!**/_.contribution.js",
  "!**/register.all.js",
]);
const definitions = new Map<string, () => Promise<ConfModule>>();
for (const [path, load] of Object.entries(definitionModules)) {
  const match = path.match(/\/definitions\/([^/]+)\/([^/]+)\.js$/);
  if (match && match[1] === match[2]) definitions.set(match[1], load);
}

/** Shiki ids whose Monaco definition has another name. */
const DEFINITION_FOR: Record<string, string> = {
  shellscript: "shell",
  docker: "dockerfile",
  c: "cpp",
  "objective-cpp": "objective-c",
  tsx: "typescript",
  jsx: "javascript",
  proto: "protobuf",
  rst: "restructuredtext",
  vue: "html",
  svelte: "html",
  astro: "html",
  "vue-html": "html",
  glsl: "cpp",
  hlsl: "cpp",
  cuda: "cpp",
  d: "cpp",
  zig: "cpp",
  groovy: "java",
  "angular-ts": "typescript",
  "angular-html": "html",
};

/** Line comments of languages without a Monaco definition. */
const LINE_COMMENT: Record<string, string> = {
  make: "#",
  makefile: "#",
  toml: "#",
  dotenv: "#",
  nginx: "#",
  "ssh-config": "#",
  cmake: "#",
  nix: "#",
  fish: "#",
  nushell: "#",
  just: "#",
  codeowners: "#",
  properties: "#",
  "git-commit": "#",
  "git-rebase": "#",
  awk: "#",
  jsonc: "//",
  json5: "//",
  haskell: "--",
  elm: "--",
  ada: "--",
  vhdl: "--",
  applescript: "--",
  lisp: ";",
  "emacs-lisp": ";",
  fennel: ";",
  asm: ";",
  latex: "%",
  tex: "%",
  erlang: "%",
  matlab: "%",
  prolog: "%",
  viml: '"',
};

const canonicalId = new Map<string, string>();
for (const info of bundledLanguagesInfo) {
  canonicalId.set(info.id, info.id);
  for (const alias of info.aliases ?? []) canonicalId.set(alias, info.id);
}

async function languageConfiguration(id: string): Promise<monaco.languages.LanguageConfiguration> {
  const canonical = canonicalId.get(id) ?? id;
  const definition = definitions.get(DEFINITION_FOR[canonical] ?? canonical);
  if (definition) {
    try {
      const conf = (await definition()).conf;
      if (conf) return conf;
    } catch (error) {
      console.warn(`cmux editor: language configuration ${canonical} failed`, error);
    }
  }
  const line = LINE_COMMENT[canonical];
  const quotes = canonical.startsWith("json")
    ? [{ open: '"', close: '"', notIn: ["string"] }]
    : [
        { open: '"', close: '"', notIn: ["string", "comment"] },
        { open: "'", close: "'", notIn: ["string", "comment"] },
      ];
  return {
    comments: line
      ? { lineComment: line }
      : canonical.startsWith("json")
        ? undefined
        : { lineComment: "//", blockComment: ["/*", "*/"] },
    brackets: [
      ["{", "}"],
      ["[", "]"],
      ["(", ")"],
    ],
    autoClosingPairs: [{ open: "{", close: "}" }, { open: "[", close: "]" }, { open: "(", close: ")" }, ...quotes],
    surroundingPairs: [
      { open: "{", close: "}" },
      { open: "[", close: "]" },
      { open: "(", close: ")" },
      { open: '"', close: '"' },
      { open: "'", close: "'" },
    ],
  };
}

/** A tokenizer state whose equality is the grammar's rule stack equality. */
class ComparableState implements monaco.languages.IState {
  constructor(readonly inner: monaco.languages.IState & { ruleStack?: { equals(other: unknown): boolean } }) {}
  clone(): ComparableState {
    return this;
  }
  equals(other: monaco.languages.IState): boolean {
    if (!(other instanceof ComparableState)) return false;
    if (other.inner === this.inner) return true;
    const mine = this.inner.ruleStack;
    const theirs = other.inner.ruleStack;
    return !!mine && !!theirs && (mine === theirs || mine.equals(theirs));
  }
}

/**
 * @shikijs/monaco's states compare by identity, so Monaco never sees a re-tokenized line end in the
 * state it had and re-tokenizes every line below an edit. Comparing the TextMate rule stacks (immutable,
 * with structural `equals`) lets Monaco stop at the first line whose state did not change.
 */
function withComparableStates(provider: monaco.languages.TokensProvider): monaco.languages.TokensProvider {
  return {
    getInitialState: () => new ComparableState(provider.getInitialState() as ComparableState["inner"]),
    tokenize(line, state) {
      const result = provider.tokenize(line, (state as ComparableState).inner);
      return { tokens: result.tokens, endState: new ComparableState(result.endState as ComparableState["inner"]) };
    },
  };
}

/**
 * The regex engine: Oniguruma (the diff viewer's, WebAssembly, the same `shiki-wasm` chunk) when the
 * page's CSP allows 'wasm-unsafe-eval', else Shiki's JavaScript engine. Measured on a 1 MB TypeScript
 * file, WebKit tokenizes it in 1.1 s with Oniguruma and 17.4 s with the JavaScript engine, and typing
 * is twice as slow while that runs; Chromium takes 0.9 s and 1.3 s.
 */
async function regexEngine() {
  try {
    const engine = await createOnigurumaEngine(import("shiki/wasm"));
    document.documentElement.dataset.cmuxEditorEngine = "oniguruma";
    return engine;
  } catch {
    document.documentElement.dataset.cmuxEditorEngine = "javascript";
    return createJavaScriptRegexEngine({ forgiving: true });
  }
}

export interface ViewLook {
  settings: EditorSettings;
  section: unknown;
  appearance: DiffViewerAppearance | undefined;
  syntaxTheme: unknown;
  languages: unknown;
  screenReader: boolean;
}

export interface ViewCallbacks {
  /** The user changed the document. */
  onUserEdit(): void;
  /** Cursor, language or line endings changed (the status bar). */
  onStatus(status: ViewStatus): void;
  /** A link the user followed. */
  openLink(href: string): void;
  label(key: "editor" | "readOnly" | "wordWrap", path: string): string;
  /** Opt-Z (VS Code's Toggle Word Wrap): flips `editor.wordWrap` through the settings store. */
  toggleWordWrap?(): void;
  /**
   * Opens the app's native command palette (`cmux.app.action.run {action: "commandPalette"}`).
   * Monaco's own command palette (F1, the context menu's Command Palette) runs this instead: the
   * editor never shows a palette of its own (Lawrence 2026-10-19).
   */
  openCommandPalette?(): void;
  /**
   * Monaco started or ended a key sequence (Cmd-K, then a second key): while one is pending the
   * app's key dispatcher lets the next key reach the editor (`cmux.editor.keySequence`).
   */
  onKeySequence?(pending: boolean): void;
  /**
   * Find (Cmd-F, Cmd-G, Shift-Cmd-G, Cmd-E, and their page commands) runs the shared find pill
   * (editorFind.ts) instead of Monaco's find widget. Returns false to leave the command to Monaco.
   */
  find?(command: FindCommand, text?: string): boolean;
  /** The document's text changed (find searches again). */
  onContentChange?(): void;
}

/** The page commands the shared find pill runs. */
export type FindCommand = "find" | "findNext" | "findPrevious" | "useSelectionForFind" | "hideFind" | "replace";
const FIND_COMMANDS: ReadonlySet<string> = new Set<FindCommand>([
  "find",
  "findNext",
  "findPrevious",
  "useSelectionForFind",
  "hideFind",
  "replace",
]);

export interface ViewStatus {
  line: number;
  column: number;
  selections: number;
  language: string;
  languageName: string;
  eol: "LF" | "CRLF" | "CR" | "mixed";
  bom: boolean;
  tabSize: number;
  insertSpaces: boolean;
  large: boolean;
  highlighted: boolean;
}

/** Set once the Shiki themes are Monaco's (Monaco's themes are global): stand-ins never replace them. */
let shikiThemesDefined = false;

/** Light and dark themes with no token colors, defined before Monaco is created (`MonacoView`). */
function defineStandInThemes(chrome: Record<string, string>): void {
  if (shikiThemesDefined) return;
  monaco.editor.defineTheme(LIGHT_THEME, { base: "vs", inherit: true, rules: [], colors: chrome });
  monaco.editor.defineTheme(DARK_THEME, { base: "vs-dark", inherit: true, rules: [], colors: chrome });
}

/** Monaco plus Shiki for one page. */
export class MonacoView implements CodeView {
  private readonly editor: monaco.editor.IStandaloneCodeEditor;
  private model: monaco.editor.ITextModel | null = null;
  private endings: LineEndings | null = null;
  private documentInfo: { path: string; size: number; readOnly: boolean } | null = null;
  private readonly syntax: SyntaxEngine;
  private readonly bound = new Map<string, { editor: { setTheme(name: string): void } }>();
  private readonly registered = new Set<string>(["plaintext"]);
  private look: ViewLook;
  private language = PLAIN_TEXT_LANGUAGE;
  private applyingLoad = false;
  private readonly disposables: monaco.IDisposable[] = [];
  private readonly scheme = matchMedia("(prefers-color-scheme: dark)");
  private themesKey = "";
  private loadToken = 0;

  constructor(
    private readonly container: HTMLElement,
    look: ViewLook,
    private readonly callbacks: ViewCallbacks,
  ) {
    this.look = look;
    this.syntax = new SyntaxEngine(
      {
        bundledLanguages: bundledLanguages as never,
        bundledThemes: bundledThemes as never,
        extensionMap: EXTENSION_TO_FILE_FORMAT as Readonly<Record<string, string>>,
        createHighlighter: async (themes) => createHighlighterCore({ themes, langs: [], engine: await regexEngine() }),
      },
      editorThemes({ bundledThemes: bundledThemes as never }, look.syntaxTheme, look.appearance),
    );
    this.themesKey = editorThemesKey(look);
    this.syntax.installLanguages(look.languages);
    this.defineChromeThemes();
    // Monaco paints its first frame in the theme it is created with. An unknown name falls back to
    // its light `vs` theme (white background), so both names exist before `create`: the Shiki
    // themes load asynchronously, and until then a theme with the right base and the page's chrome
    // colors stands in (user 2026-10-20, "for monaco editors there is flash of wrong theme").
    defineStandInThemes(this.chrome);
    this.editor = monaco.editor.create(container, {
      ...this.editorOptions(),
      model: null,
      theme: this.themeName(),
    } as monaco.editor.IStandaloneEditorConstructionOptions);
    this.disposables.push(
      monaco.editor.registerLinkOpener({
        open: (uri) => {
          this.callbacks.openLink(uri.toString(true));
          return true;
        },
      }),
      this.editor.onDidChangeCursorSelection(() => this.reportStatus()),
      // A right-click opens the app's standard macOS menu, not Monaco's (nativeEditorMenu.ts).
      installNativeEditorMenu(this.editor, container, {
        [MONACO_QUICK_COMMAND]: () => this.callbacks.openCommandPalette?.(),
      }),
      // Overlay scrollers show while the editor scrolls (scrollers.ts MONACO_SCROLLER_CSS). Monaco
      // reports a new scroll size too (its first layout, a pane or window resize); that is not a scroll.
      this.editor.onDidScrollChange((event) => {
        const node = this.editor.getDomNode();
        if (node && (event.scrollTopChanged || event.scrollLeftChanged)) markScrolling(node);
      }),
      {
        dispose: onScrollerStyleChange(() => this.editor.updateOptions(this.editorOptions()), document.documentElement),
      },
    );
    this.scheme.addEventListener("change", this.onSchemeChange);
    this.disposables.push(
      // VS Code's Opt-Z. Monaco has no word wrap toggle of its own; the id is VS Code's, so an
      // `editor.keybindings` rule can move it.
      this.editor.addAction({
        id: TOGGLE_WORD_WRAP,
        label: this.callbacks.label("wordWrap", ""),
        keybindings: [monaco.KeyMod.Alt | monaco.KeyCode.KeyZ],
        run: () => this.callbacks.toggleWordWrap?.(),
      }),
    );
    this.disposables.push(
      // Monaco's quick command (F1, the context menu's Command Palette) is the app's native palette:
      // no web view has a palette of its own. Keys and menus run commands through Monaco's command
      // registry, where the latest registration of an id wins, so this replaces Monaco's widget.
      monaco.editor.registerCommand(MONACO_QUICK_COMMAND, () => this.callbacks.openCommandPalette?.()),
    );
    this.disposables.push(
      // The find chords Monaco binds itself open the shared find pill, never Monaco's widget (the
      // app's dispatcher sends the same commands as page commands; these cover a key that reaches
      // Monaco first). Registered after Monaco's find contribution, so they win.
      ...(
        [
          ["find", monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyF],
          ["findNext", monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyG],
          ["findPrevious", monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyG],
          ["useSelectionForFind", monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyE],
          ["replace", monaco.KeyMod.CtrlCmd | monaco.KeyMod.Alt | monaco.KeyCode.KeyF],
        ] as const
      ).map(([command, key]) =>
        this.editor.addAction({
          id: `cmux.find.${command}`,
          label: command,
          keybindings: [key],
          run: () => void this.callbacks.find?.(command),
        }),
      ),
      this.editor.onDidChangeModelContent(() => this.callbacks.onContentChange?.()),
    );
    this.applyKeybindings();
    this.watchKeySequences(container);
    // The Shiki themes replace the stand-ins as soon as the highlighter is up, also for plain text.
    void this.applyTheme();
  }

  /** The `editor.keybindings` rules applied now (and their key), so a look change re-applies them once. */
  private keybindingDisposable: monaco.IDisposable | null = null;
  private keybindingsKey = "";

  private applyKeybindings(): void {
    const entries = this.look.settings.keybindings;
    const key = JSON.stringify(entries);
    if (key === this.keybindingsKey) return;
    this.keybindingsKey = key;
    this.keybindingDisposable?.dispose();
    const rules = keybindingRules(entries, monaco as never);
    this.keybindingDisposable = rules.length > 0 ? monaco.editor.addKeybindingRules(rules) : null;
  }

  /**
   * Tells the host when Monaco waits for the second key of a sequence (Cmd-K Cmd-0): the app's
   * dispatcher resolves every Command chord first, so without this it took the second key (Cmd-0
   * reset the zoom, Cmd-J opened the app's leader) and the sequence never finished.
   */
  private watchKeySequences(container: HTMLElement): void {
    let pending = false;
    const check = () => {
      const service = (this.editor as unknown as { _standaloneKeybindingService?: { inChordMode?: boolean } })
        ._standaloneKeybindingService;
      const now = service?.inChordMode === true;
      if (now === pending) return;
      pending = now;
      this.callbacks.onKeySequence?.(now);
    };
    // After Monaco's own keydown handler (on the editor's node) has run.
    const onKeyDown = () => setTimeout(check, 0);
    // ui-allow: reads Monaco's chord state after its keydown; Monaco owns the keys.
    container.addEventListener("keydown", onKeyDown);
    const onBlur = () => setTimeout(check, 0);
    container.addEventListener("focusout", onBlur);
    this.disposables.push({
      dispose: () => {
        container.removeEventListener("keydown", onKeyDown);
        container.removeEventListener("focusout", onBlur);
      },
    });
  }

  private onSchemeChange = () => this.applyTheme();

  /**
   * The page's scheme: the host's theme sets `color-scheme` on the root (WebTheme.swift), which the
   * page's `light-dark()` colors follow, so Monaco follows it too; the system's otherwise.
   */
  private themeName(): string {
    const scheme = getComputedStyle(document.documentElement).colorScheme.trim();
    const dark = scheme === "dark" ? true : scheme === "light" ? false : this.scheme.matches;
    return dark ? DARK_THEME : LIGHT_THEME;
  }

  private large(): boolean {
    return this.documentInfo ? isLargeFile(this.documentInfo.size, this.look.settings) : false;
  }

  private languageSettings(): EditorSettings {
    return settingsForLanguage(this.look.settings, this.syntax.displayName(this.language), this.look.section);
  }

  private editorOptions(): monaco.editor.IEditorOptions {
    const info = this.documentInfo;
    const settings = this.languageSettings();
    const accessibility =
      settings.accessibilitySupport === "auto" && this.look.screenReader ? "on" : settings.accessibilitySupport;
    return monacoOptions({ ...settings, accessibilitySupport: accessibility }, this.look.appearance, {
      readOnly: info?.readOnly ?? true,
      large: this.large(),
      ariaLabel: this.callbacks.label("editor", info?.path ?? ""),
      readOnlyMessage: info?.readOnly ? this.callbacks.label("readOnly", info.path) : undefined,
      scrollers: scrollerStyle(),
    }) as monaco.editor.IEditorOptions;
  }

  /**
   * Monaco themes for the two Shiki themes, with the editor chrome colors from the page's
   * `--cmux-editor-*` properties (so theme.css changes the editor too). Token rules come from Shiki.
   */
  private defineChromeThemes(): void {
    const chrome: Record<string, string> = {};
    const style = getComputedStyle(this.container);
    for (const [variable, keys] of MONACO_THEME_VARIABLES) {
      const color = cssColorToHex(style.getPropertyValue(variable), this.container);
      if (color) for (const key of keys) chrome[key] = color;
    }
    this.chrome = chrome;
  }
  private chrome: Record<string, string> = {};

  private patch(theme: monaco.editor.IStandaloneThemeData): monaco.editor.IStandaloneThemeData {
    const colors: Record<string, string> = {};
    // Shiki's colors may be CSS keywords (`transparent`) Monaco cannot parse; keep hex colors only.
    for (const [key, value] of Object.entries(theme.colors)) if (/^#[0-9a-f]{3,8}$/i.test(value)) colors[key] = value;
    return { ...theme, colors: { ...colors, ...this.chrome } };
  }

  /** Re-applies the theme: the scheme, the chrome colors or the Shiki themes changed. */
  private async applyTheme(): Promise<void> {
    // The scheme switches in this frame, with the page's colors; the Shiki colors follow.
    const shown = this.themeName();
    for (const binding of this.bound.values()) binding.editor.setTheme(shown);
    monaco.editor.setTheme(shown);
    const highlighter = await this.syntax.getHighlighter();
    this.defineChromeThemes();
    for (const id of [LIGHT_THEME, DARK_THEME]) {
      monaco.editor.defineTheme(id, this.patch(textmateThemeToMonacoTheme(highlighter.getTheme(id)) as never));
    }
    shikiThemesDefined = true;
    const name = this.themeName();
    for (const binding of this.bound.values()) binding.editor.setTheme(name);
    monaco.editor.setTheme(name);
  }

  /**
   * Binds one loaded Shiki language to Monaco through @shikijs/monaco. A facade receives what it
   * patches (setTheme, create) so each binding keeps its own color map and the real Monaco API stays
   * untouched; `applyTheme` drives every binding.
   */
  private async bind(id: string): Promise<void> {
    if (this.bound.has(id)) return;
    const highlighter = await this.syntax.getHighlighter();
    if (!this.registered.has(id)) {
      monaco.languages.register({ id });
      this.registered.add(id);
      monaco.languages.setLanguageConfiguration(id, await languageConfiguration(id));
    }
    const facade = {
      editor: {
        defineTheme: (name: string, theme: monaco.editor.IStandaloneThemeData) =>
          monaco.editor.defineTheme(name, this.patch(theme)),
        setTheme: (_name: string) => {},
        create: monaco.editor.create,
      },
      languages: {
        getLanguages: () => [{ id }],
        setTokensProvider: (language: string, provider: monaco.languages.TokensProvider) =>
          monaco.languages.setTokensProvider(language, withComparableStates(provider)),
      },
    };
    shikiToMonaco(highlighter, facade as never);
    this.bound.set(id, facade);
    facade.editor.setTheme(this.themeName());
    monaco.editor.setTheme(this.themeName());
  }

  load(document: EditorDocument): void {
    const token = ++this.loadToken;
    const shape = analyzeText(document.text);
    this.endings = new LineEndings(shape);
    this.eolLabel = lineEndingLabel(shape);
    this.documentInfo = { path: document.path, size: document.size, readOnly: document.readOnly };
    const firstLine = shape.body.slice(0, Math.min(shape.body.length, 512)).split(/\r\n|\r|\n/, 1)[0];
    const detected = this.syntax.detect(document.path, firstLine);
    this.language = detected.id;
    const large = this.large();
    const previous = this.model;
    // The model always starts as plain text; the grammar binds when it has loaded.
    const uri = monaco.Uri.from({ scheme: "cmux-editor", path: document.path, query: String(token) });
    const model = monaco.editor.createModel(shape.body, "plaintext", uri);
    model.setEOL(shape.eol === "\r\n" ? monaco.editor.EndOfLineSequence.CRLF : monaco.editor.EndOfLineSequence.LF);
    const indentation = modelOptions(this.languageSettings());
    if (indentation.detect) model.detectIndentation(indentation.insertSpaces, indentation.tabSize);
    else model.updateOptions({ tabSize: indentation.tabSize, insertSpaces: indentation.insertSpaces });
    this.model = model;
    this.applyingLoad = true;
    this.editor.setModel(model);
    this.applyingLoad = false;
    this.editor.updateOptions(this.editorOptions());
    this.modelListener?.dispose();
    previous?.dispose();
    this.modelListener = model.onDidChangeContent((event) => {
      this.endings?.apply(event.changes.map((change) => ({ ...change.range, text: change.text })));
      if (!this.applyingLoad && !event.isFlush) this.callbacks.onUserEdit();
    });
    this.highlighted = false;
    this.reportStatus();
    if (!large && detected.id !== PLAIN_TEXT_LANGUAGE) {
      void this.syntax.load(detected.id).then(async (ok) => {
        if (!ok || token !== this.loadToken || model.isDisposed()) return;
        await this.bind(detected.id);
        if (token !== this.loadToken || model.isDisposed()) return;
        monaco.editor.setModelLanguage(model, detected.id);
        this.highlighted = true;
        this.reportStatus();
      });
    }
  }
  private highlighted = false;
  private eolLabel: ViewStatus["eol"] = "LF";
  private modelListener: monaco.IDisposable | null = null;

  /** The look changed: options, theme, languages. */
  setLook(look: ViewLook): void {
    const themesKey = editorThemesKey(look);
    const languagesChanged = JSON.stringify(look.languages ?? null) !== JSON.stringify(this.look.languages ?? null);
    this.look = look;
    if (languagesChanged) this.syntax.installLanguages(look.languages);
    this.editor.updateOptions(this.editorOptions());
    this.applyKeybindings();
    if (themesKey !== this.themesKey) {
      this.themesKey = themesKey;
      void this.syntax
        .setThemes(editorThemes({ bundledThemes: bundledThemes as never }, look.syntaxTheme, look.appearance))
        .then(async () => {
          // A binding maps colors back to theme scopes; new themes need new bindings.
          const ids = [...this.bound.keys()];
          this.bound.clear();
          for (const id of ids) await this.bind(id);
          await this.applyTheme();
        });
    } else {
      void this.applyTheme();
    }
    this.reportStatus();
  }

  private reportStatus(): void {
    const model = this.model;
    if (!model || !this.endings) return;
    const position = this.editor.getPosition();
    const options = model.getOptions();
    this.callbacks.onStatus({
      line: position?.lineNumber ?? 1,
      column: position?.column ?? 1,
      selections: this.editor.getSelections()?.length ?? 1,
      language: this.language,
      languageName: this.syntax.displayName(this.language),
      eol: this.eolLabel,
      bom: this.endings.bom,
      tabSize: options.tabSize,
      insertSpaces: options.insertSpaces,
      large: this.large(),
      highlighted: this.highlighted,
    });
  }

  text(): string {
    const model = this.model;
    if (!model || !this.endings) return "";
    return this.endings.encode(model.getLinesContent());
  }

  version(): number {
    return this.model?.getAlternativeVersionId() ?? 0;
  }

  /** The whole document replaced as one undoable edit (a recovered draft); the store reports it. */
  replaceText(text: string): void {
    const model = this.model;
    if (!model) return;
    const body = analyzeText(text).body;
    this.applyingLoad = true;
    this.editor.executeEdits("cmux-recovery", [{ range: model.getFullModelRange(), text: body }]);
    this.applyingLoad = false;
  }

  setReadOnly(readOnly: boolean): void {
    if (this.documentInfo) this.documentInfo.readOnly = readOnly;
    this.editor.updateOptions(this.editorOptions());
  }

  /**
   * VS Code's save options on an explicit save (as format on save): trailing spaces removed and a
   * final newline added, as one undoable edit. Off by default; the file is otherwise never rewritten.
   */
  async prepareSave(options: { trimTrailingWhitespace: boolean; insertFinalNewline: boolean }): Promise<void> {
    const model = this.model;
    if (!model || this.documentInfo?.readOnly) return;
    if (options.trimTrailingWhitespace) {
      const action = this.editor.getAction("editor.action.trimTrailingWhitespace");
      if (action?.isSupported()) await action.run();
    }
    if (options.insertFinalNewline) {
      const last = model.getLineCount();
      if (model.getLineContent(last) !== "") {
        const column = model.getLineMaxColumn(last);
        this.editor.executeEdits("cmux-save", [
          { range: new monaco.Range(last, column, last, column), text: model.getEOL() },
        ]);
      }
    }
  }

  async format(): Promise<void> {
    const action = this.editor.getAction("editor.action.formatDocument");
    if (action?.isSupported()) await action.run();
  }

  /** The selection's text and lines (viewer comments, viewer-comments-DESIGN.md), null with nothing
   * selected. A selection that ends at the start of a line does not count that line. */
  selectionQuote(): { text: string; startLine: number; endLine: number } | null {
    const selection = this.editor.getSelection();
    const model = this.editor.getModel();
    if (!selection || !model || selection.isEmpty()) return null;
    const text = model.getValueInRange(selection);
    if (!text.trim()) return null;
    let endLine = selection.endLineNumber;
    if (selection.endColumn === 1 && endLine > selection.startLineNumber) endLine--;
    return { text, startLine: selection.startLineNumber, endLine };
  }

  focus(): void {
    this.editor.focus();
  }

  /** The editor as the shared find pill searches it (editorFind.ts). */
  findTarget(): FindTarget {
    const decorations = this.editor.createDecorationsCollection();
    return {
      // Monaco's own default stops at 999; the pill takes MATCH_LIMIT, Replace All takes them all.
      findMatches: (query, matchCase, all) =>
        this.model
          ?.findMatches(query, false, false, matchCase, null, false, all ? Number.MAX_SAFE_INTEGER : MATCH_LIMIT)
          .map((match) => match.range) ?? [],
      // The selection's start, not the cursor: a selected match leaves the cursor at its end, and
      // the next letter typed would skip to the match after it.
      caret: () =>
        this.editor.getSelection()?.getStartPosition() ?? this.editor.getPosition() ?? { lineNumber: 1, column: 1 },
      selectedText: () => {
        const selection = this.editor.getSelection();
        if (!selection || !this.model || selection.isEmpty()) return "";
        if (selection.startLineNumber !== selection.endLineNumber) return "";
        return this.model.getValueInRange(selection);
      },
      show: (matches: readonly FindRange[], active: number) => {
        // Monaco's own find classes, so the theme's find colors paint them.
        decorations.set(
          matches.map((range, index) => ({
            range,
            options: {
              className: index === active ? "currentFindMatch" : "findMatch",
              stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
              overviewRuler: { color: "rgba(246, 185, 77, 0.7)", position: monaco.editor.OverviewRulerLane.Center },
            },
          })),
        );
        const range = matches[active];
        if (!range) return;
        this.editor.setSelection(range);
        this.editor.revealRangeInCenterIfOutsideViewport(range, monaco.editor.ScrollType.Smooth);
      },
      focus: () => this.editor.focus(),
      readOnly: () => this.documentInfo?.readOnly ?? true,
      replace: (ranges, text) => {
        if (!this.model || this.documentInfo?.readOnly) return;
        // One undo step, as Monaco's Replace All.
        this.editor.pushUndoStop();
        this.editor.executeEdits(
          "cmux.find.replace",
          ranges.map((range) => ({ range, text, forceMoveMarkers: true })),
        );
        this.editor.pushUndoStop();
      },
    };
  }

  /** Moves the cursor to `position` (clamped to the document) and centers its line, then focuses. */
  reveal(position: RevealPosition): void {
    const model = this.model;
    if (!model) return;
    const lineNumber = Math.min(Math.max(1, position.line), model.getLineCount());
    const column = Math.min(Math.max(1, position.column), model.getLineMaxColumn(lineNumber));
    this.editor.setPosition({ lineNumber, column });
    this.editor.revealPositionInCenter({ lineNumber, column });
    this.editor.focus();
  }

  /** A page command from the app's key dispatcher. Returns false for an unknown command. */
  command(command: EditorCommand, text?: string): boolean {
    if (FIND_COMMANDS.has(command) && this.callbacks.find?.(command as FindCommand, text)) return true;
    const id = editorAction(command, text);
    if (!id) return false;
    if (command === "editorAction" && !isEditorAction(id)) return false;
    this.editor.focus();
    const action = this.editor.getAction(id);
    if (action) {
      void action.run();
      return true;
    }
    this.editor.trigger("cmux.page.command", id, null);
    return true;
  }

  /** For tests and the debug socket: the Monaco editor. */
  get monacoEditor(): monaco.editor.IStandaloneCodeEditor {
    return this.editor;
  }

  dispose(): void {
    this.scheme.removeEventListener("change", this.onSchemeChange);
    for (const disposable of this.disposables) disposable.dispose();
    this.modelListener?.dispose();
    this.keybindingDisposable?.dispose();
    this.model?.dispose();
    this.editor.dispose();
  }
}

/** VS Code's command id for Opt-Z; `keys.ts` lists it so an app binding can run it too. */
const TOGGLE_WORD_WRAP = "editor.action.toggleWordWrap";

/// What the editor's Shiki themes are built from: the syntax theme setting, the page's appearance
/// and the host's terminal theme (literal colors in Monaco, so a palette change rebuilds them).
function editorThemesKey(look: ViewLook): string {
  return JSON.stringify([look.syntaxTheme ?? null, look.appearance ?? null, hostTerminalTheme()]);
}
