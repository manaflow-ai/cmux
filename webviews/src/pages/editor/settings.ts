// The code editor's settings: the `editor` section of the settings store (cmux-next.json), which the
// host passes in the page config and re-sends on the look stream. Keys use Monaco's and VS Code's
// names (`editor.wordWrap`, `editor.minimap.enabled`, `editor.stickyScroll.enabled`), the shape
// users' cmux.json files already have. Behavior and layout choices are keys (customization.md rule
// 1); fine-grained look is `--cmux-editor-*` custom properties (rule 3) and
// `<config dir>/editor/theme.css` (rule 4). Fonts follow the terminal by default (the Ghostty rule):
// with no `fontFamily` or `fontSize` the editor uses the terminal font the host sends in
// `appearance`. Every key is optional; an invalid value keeps its default. Pure: no Monaco import.
import type { DiffViewerAppearance } from "../../appearance";
import { monacoScrollerOptions, type ScrollerStyle } from "../../scrollers";

export type WordWrap = "off" | "on" | "bounded" | "wordWrapColumn";
export type LineNumbers = "on" | "off" | "relative" | "interval";
export type RenderWhitespace = "none" | "boundary" | "selection" | "trailing" | "all";
export type CursorStyle = "line" | "block" | "underline" | "line-thin" | "block-outline" | "underline-thin";
export type CursorBlinking = "blink" | "smooth" | "phase" | "expand" | "solid";
export type AutoSave = "off" | "afterDelay";
export type AccessibilitySupport = "auto" | "on" | "off";

/** The keys a language may override (`editor.languages.<id>.<key>`). */
export interface LanguageOverride {
  tabSize?: number;
  insertSpaces?: boolean;
  detectIndentation?: boolean;
  wordWrap?: WordWrap;
  rulers?: number[];
  formatOnSave?: boolean;
}

/** The resolved settings. `settings.test.ts` and README.md list the same keys and defaults. */
export interface EditorSettings extends Required<Omit<LanguageOverride, "rulers">> {
  fontFamily: string | null;
  fontSize: number | null;
  fontWeight: string;
  fontLigatures: boolean;
  lineHeight: number;
  wordWrapColumn: number;
  minimap: boolean;
  lineNumbers: LineNumbers;
  rulers: number[];
  renderWhitespace: RenderWhitespace;
  cursorStyle: CursorStyle;
  cursorBlinking: CursorBlinking;
  smoothScrolling: boolean;
  bracketPairColorization: boolean;
  stickyScroll: boolean;
  folding: boolean;
  renderLineHighlight: "none" | "gutter" | "line" | "all";
  scrollBeyondLastLine: boolean;
  autoClosingBrackets: boolean;
  indentGuides: boolean;
  autoSave: AutoSave;
  autoSaveDelay: number;
  largeFileThreshold: number;
  accessibilitySupport: AccessibilitySupport;
  toolbar: boolean;
  statusBar: boolean;
  languages: Record<string, LanguageOverride>;
}

export const EDITOR_DEFAULTS: EditorSettings = {
  fontFamily: null,
  fontSize: null,
  fontWeight: "normal",
  fontLigatures: false,
  lineHeight: 0,
  tabSize: 4,
  insertSpaces: true,
  detectIndentation: true,
  wordWrap: "off",
  wordWrapColumn: 80,
  minimap: false,
  lineNumbers: "on",
  rulers: [],
  renderWhitespace: "selection",
  cursorStyle: "line",
  cursorBlinking: "blink",
  smoothScrolling: false,
  bracketPairColorization: true,
  stickyScroll: true,
  folding: true,
  renderLineHighlight: "line",
  scrollBeyondLastLine: false,
  autoClosingBrackets: true,
  indentGuides: true,
  formatOnSave: false,
  autoSave: "afterDelay",
  autoSaveDelay: 1000,
  largeFileThreshold: 8 * 1024 * 1024,
  accessibilitySupport: "auto",
  toolbar: true,
  statusBar: true,
  languages: {},
};

/** Built-in language defaults; `editor.languages.<id>` wins over these. */
export const LANGUAGE_DEFAULTS: Record<string, LanguageOverride> = {
  make: { insertSpaces: false, detectIndentation: false },
  makefile: { insertSpaces: false, detectIndentation: false },
  go: { insertSpaces: false },
  markdown: { wordWrap: "on" },
  mdx: { wordWrap: "on" },
  "git-commit": { wordWrap: "on", rulers: [72] },
};

/** The `editor.*` keys the toolbar writes through `cmux.editor.setPreference`. */
export const PREFERENCE_KEYS = { wordWrap: "editor.wordWrap", minimap: "editor.minimap.enabled" } as const;

const object = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

const oneOf = <T extends string>(value: unknown, choices: readonly T[]): T | undefined =>
  typeof value === "string" && (choices as readonly string[]).includes(value) ? (value as T) : undefined;

const bool = (value: unknown): boolean | undefined => (typeof value === "boolean" ? value : undefined);

const int = (value: unknown, min: number, max: number): number | undefined =>
  typeof value === "number" && Number.isInteger(value) && value >= min && value <= max ? value : undefined;

const num = (value: unknown, min: number, max: number): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= min && value <= max ? value : undefined;

/** A CSS-safe font family list: no rule or tag breakouts, short. */
export function fontFamilyValue(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  if (!text || text.length > 300 || /[;{}<>\\]|\/\*/.test(text)) return undefined;
  return text;
}

const WORD_WRAP = ["off", "on", "bounded", "wordWrapColumn"] as const;
const RULER_LIMIT = 8;

function rulers(value: unknown): number[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const columns = value.filter((column): column is number => int(column, 1, 1000) !== undefined);
  return columns.length === value.length ? columns.slice(0, RULER_LIMIT) : undefined;
}

function override(value: unknown): LanguageOverride {
  const root = object(value);
  const out: LanguageOverride = {};
  const tabSize = int(root.tabSize, 1, 16);
  if (tabSize !== undefined) out.tabSize = tabSize;
  const insertSpaces = bool(root.insertSpaces);
  if (insertSpaces !== undefined) out.insertSpaces = insertSpaces;
  const detect = bool(root.detectIndentation);
  if (detect !== undefined) out.detectIndentation = detect;
  const wrap = oneOf(root.wordWrap, WORD_WRAP);
  if (wrap) out.wordWrap = wrap;
  const columns = rulers(root.rulers);
  if (columns) out.rulers = columns;
  const format = bool(root.formatOnSave);
  if (format !== undefined) out.formatOnSave = format;
  return out;
}

/** `true`/`false`, or Monaco's `{enabled}` object form (`editor.minimap.enabled`). */
const enabled = (value: unknown): boolean | undefined =>
  bool(value) ?? (value && typeof value === "object" ? bool((value as { enabled?: unknown }).enabled) : undefined);

/**
 * The `editor` section resolved against the defaults. README.md lists every key: `fontFamily`,
 * `fontSize`, `fontWeight`, `fontLigatures`, `lineHeight`, `tabSize`, `insertSpaces`,
 * `detectIndentation`, `wordWrap`, `wordWrapColumn`, `minimap.enabled`, `lineNumbers`, `rulers`,
 * `renderWhitespace`, `cursorStyle`, `cursorBlinking`, `smoothScrolling`,
 * `bracketPairColorization.enabled`, `stickyScroll.enabled`, `folding`, `renderLineHighlight`,
 * `scrollBeyondLastLine`, `autoClosingBrackets`, `guides.indentation`, `formatOnSave`, `autoSave`,
 * `autoSaveDelay`, `largeFileThreshold`, `accessibilitySupport`, `toolbar`, `statusBar`,
 * `languages.<id>`.
 */
export function resolveEditorSettings(section: unknown): EditorSettings {
  const root = object(section);
  const base = override(root);
  const languages: Record<string, LanguageOverride> = {};
  for (const [id, value] of Object.entries(object(root.languages))) {
    if (/^[a-z0-9][a-z0-9+#._-]{0,63}$/i.test(id)) languages[id.toLowerCase()] = override(value);
  }
  const d = EDITOR_DEFAULTS;
  const closing = root.autoClosingBrackets;
  return {
    fontFamily: fontFamilyValue(root.fontFamily) ?? d.fontFamily,
    fontSize: num(root.fontSize, 6, 72) ?? d.fontSize,
    fontWeight:
      typeof root.fontWeight === "number" && int(root.fontWeight, 100, 900) !== undefined
        ? String(root.fontWeight)
        : (oneOf(root.fontWeight, [
            "normal",
            "bold",
            "100",
            "200",
            "300",
            "400",
            "500",
            "600",
            "700",
            "800",
            "900",
          ] as const) ?? d.fontWeight),
    fontLigatures: bool(root.fontLigatures) ?? d.fontLigatures,
    lineHeight: num(root.lineHeight, 0, 150) ?? d.lineHeight,
    tabSize: base.tabSize ?? d.tabSize,
    insertSpaces: base.insertSpaces ?? d.insertSpaces,
    detectIndentation: base.detectIndentation ?? d.detectIndentation,
    wordWrap: base.wordWrap ?? d.wordWrap,
    wordWrapColumn: int(root.wordWrapColumn, 10, 1000) ?? d.wordWrapColumn,
    minimap: enabled(root.minimap) ?? d.minimap,
    lineNumbers: oneOf(root.lineNumbers, ["on", "off", "relative", "interval"] as const) ?? d.lineNumbers,
    rulers: base.rulers ?? d.rulers,
    renderWhitespace:
      oneOf(root.renderWhitespace, ["none", "boundary", "selection", "trailing", "all"] as const) ?? d.renderWhitespace,
    cursorStyle:
      oneOf(root.cursorStyle, [
        "line",
        "block",
        "underline",
        "line-thin",
        "block-outline",
        "underline-thin",
      ] as const) ?? d.cursorStyle,
    cursorBlinking:
      oneOf(root.cursorBlinking, ["blink", "smooth", "phase", "expand", "solid"] as const) ?? d.cursorBlinking,
    smoothScrolling: bool(root.smoothScrolling) ?? d.smoothScrolling,
    bracketPairColorization: enabled(root.bracketPairColorization) ?? d.bracketPairColorization,
    stickyScroll: enabled(root.stickyScroll) ?? d.stickyScroll,
    folding: bool(root.folding) ?? d.folding,
    renderLineHighlight:
      oneOf(root.renderLineHighlight, ["none", "gutter", "line", "all"] as const) ?? d.renderLineHighlight,
    scrollBeyondLastLine: bool(root.scrollBeyondLastLine) ?? d.scrollBeyondLastLine,
    autoClosingBrackets:
      bool(closing) ?? (typeof closing === "string" ? closing !== "never" : undefined) ?? d.autoClosingBrackets,
    indentGuides: bool(object(root.guides).indentation) ?? d.indentGuides,
    formatOnSave: base.formatOnSave ?? d.formatOnSave,
    autoSave: oneOf(root.autoSave, ["off", "afterDelay"] as const) ?? d.autoSave,
    autoSaveDelay: int(root.autoSaveDelay, 100, 60_000) ?? d.autoSaveDelay,
    largeFileThreshold: int(root.largeFileThreshold, 0, 2 ** 31) ?? d.largeFileThreshold,
    accessibilitySupport: oneOf(root.accessibilitySupport, ["auto", "on", "off"] as const) ?? d.accessibilitySupport,
    toolbar: bool(root.toolbar) ?? d.toolbar,
    statusBar: bool(root.statusBar) ?? d.statusBar,
    languages,
  };
}

/** The settings for one language: built-in language defaults, then the user's override. */
export function settingsForLanguage(settings: EditorSettings, language: string, section?: unknown): EditorSettings {
  const id = language.toLowerCase();
  // A language default applies only where the user did not set the key at the top level.
  const top = object(section);
  const builtIn = LANGUAGE_DEFAULTS[id] ?? {};
  const fromBuiltIn: LanguageOverride = {};
  for (const [key, value] of Object.entries(builtIn) as Array<[keyof LanguageOverride, never]>) {
    if (top[key] === undefined) (fromBuiltIn as Record<string, unknown>)[key] = value;
  }
  return { ...settings, ...fromBuiltIn, ...settings.languages[id] };
}

/** Whether a file is large enough that the editor turns its costly features off. */
export function isLargeFile(size: number, settings: Pick<EditorSettings, "largeFileThreshold">): boolean {
  return settings.largeFileThreshold > 0 && size >= settings.largeFileThreshold;
}

/** The terminal font the editor follows by default, from the host's appearance. */
export function editorFont(
  settings: Pick<EditorSettings, "fontFamily" | "fontSize">,
  appearance: DiffViewerAppearance | undefined,
): { family: string; size: number } {
  const terminal =
    typeof appearance?.fontFamily === "string" && appearance.fontFamily.trim() ? appearance.fontFamily : null;
  const family =
    settings.fontFamily ??
    `${terminal ? `${JSON.stringify(terminal.trim())}, ` : ""}ui-monospace, SFMono-Regular, Menlo, Monaco, monospace`;
  const terminalSize =
    typeof appearance?.fontSize === "number" && Number.isFinite(appearance.fontSize) && appearance.fontSize > 0
      ? appearance.fontSize
      : 12;
  return { family, size: settings.fontSize ?? terminalSize };
}

/** The Monaco editor options (IEditorOptions shape) for the resolved settings. */
export function monacoOptions(
  settings: EditorSettings,
  appearance: DiffViewerAppearance | undefined,
  context: {
    readOnly: boolean;
    large: boolean;
    ariaLabel: string;
    readOnlyMessage?: string;
    scrollers?: ScrollerStyle;
  },
): Record<string, unknown> {
  const font = editorFont(settings, appearance);
  const large = context.large;
  const scrollerOptions = monacoScrollerOptions(context.scrollers ?? "overlay");
  const options: Record<string, unknown> = {
    fontFamily: font.family,
    fontSize: font.size,
    fontWeight: settings.fontWeight,
    fontLigatures: settings.fontLigatures,
    lineHeight: settings.lineHeight,
    wordWrap: settings.wordWrap,
    wordWrapColumn: settings.wordWrapColumn,
    minimap: { enabled: settings.minimap && !large },
    lineNumbers: settings.lineNumbers,
    rulers: settings.rulers,
    renderWhitespace: settings.renderWhitespace,
    cursorStyle: settings.cursorStyle,
    cursorBlinking: settings.cursorBlinking,
    smoothScrolling: settings.smoothScrolling,
    bracketPairColorization: { enabled: settings.bracketPairColorization && !large },
    guides: { indentation: settings.indentGuides && !large, bracketPairs: false },
    stickyScroll: { enabled: settings.stickyScroll && !large },
    folding: settings.folding && !large,
    renderLineHighlight: settings.renderLineHighlight,
    scrollBeyondLastLine: settings.scrollBeyondLastLine,
    autoClosingBrackets: settings.autoClosingBrackets ? "languageDefined" : "never",
    autoClosingQuotes: settings.autoClosingBrackets ? "languageDefined" : "never",
    accessibilitySupport: settings.accessibilitySupport,
    ariaLabel: context.ariaLabel,
    readOnly: context.readOnly,
    readOnlyMessage: { value: context.readOnlyMessage ?? "" },
    domReadOnly: false,
    // A file is written only by the user's edits: Monaco never rewrites line terminators itself.
    unusualLineTerminators: "off",
    // Large files: everything that walks the whole document stays off.
    occurrencesHighlight: large ? "off" : "singleFile",
    selectionHighlight: !large,
    links: !large,
    colorDecorators: !large,
    wordBasedSuggestions: large ? "off" : "currentDocument",
    unicodeHighlight: { ambiguousCharacters: !large, invisibleCharacters: !large },
    largeFileOptimizations: true,
    maxTokenizationLineLength: 20_000,
    automaticLayout: true,
    fixedOverflowWidgets: true,
    // The macOS "Show scroll bars" setting from the host (scrollers.ts).
    ...scrollerOptions,
    // The page is the scroller's only owner; the native view handles the window.
    scrollbar: { ...scrollerOptions.scrollbar, alwaysConsumeMouseWheel: false },
    // Monaco's own context menu inside the editor (R139 allows it); no popup while typing.
    contextmenu: true,
    quickSuggestions: false,
    padding: { top: 4 },
  };
  return options;
}

/** The model options (indentation) for one language's settings. */
export function modelOptions(settings: EditorSettings): { tabSize: number; insertSpaces: boolean; detect: boolean } {
  return { tabSize: settings.tabSize, insertSpaces: settings.insertSpaces, detect: settings.detectIndentation };
}

/** Every `--cmux-editor-*` property and its default. styles.css declares the same defaults. */
export const EDITOR_STYLE_DEFAULTS = {
  "--cmux-editor-background": "transparent",
  "--cmux-editor-foreground": "var(--cmux-editor-terminal-foreground, var(--page-text))",
  "--cmux-editor-line-highlight": "color-mix(in srgb, var(--cmux-editor-foreground) 5%, transparent)",
  "--cmux-editor-selection": "var(--cmux-editor-terminal-selection, color-mix(in srgb, #0a84ff 30%, transparent))",
  "--cmux-editor-cursor": "var(--cmux-editor-foreground)",
  "--cmux-editor-line-number": "color-mix(in srgb, var(--cmux-editor-foreground) 40%, transparent)",
  "--cmux-editor-line-number-active": "color-mix(in srgb, var(--cmux-editor-foreground) 80%, transparent)",
  "--cmux-editor-indent-guide": "color-mix(in srgb, var(--cmux-editor-foreground) 10%, transparent)",
  "--cmux-editor-whitespace": "color-mix(in srgb, var(--cmux-editor-foreground) 25%, transparent)",
  "--cmux-editor-ruler": "color-mix(in srgb, var(--cmux-editor-foreground) 12%, transparent)",
  "--cmux-editor-scrollbar": "color-mix(in srgb, var(--cmux-editor-foreground) 18%, transparent)",
  "--cmux-editor-scrollbar-hover": "color-mix(in srgb, var(--cmux-editor-foreground) 28%, transparent)",
  "--cmux-editor-widget-background": "var(--page-elevated)",
  "--cmux-editor-widget-border": "var(--page-separator)",
  "--cmux-editor-chrome-font-size": "12px",
  "--cmux-editor-toolbar-height": "30px",
  "--cmux-editor-status-height": "22px",
  "--cmux-editor-banner-background": "light-dark(rgb(255 196 0 / 0.16), rgb(255 196 0 / 0.12))",
  "--cmux-editor-error-color": "light-dark(#b42318, #ff8a80)",
} as const;

export type EditorStyleVariable = keyof typeof EDITOR_STYLE_DEFAULTS;

/** The `--cmux-editor-*` properties that become Monaco theme colors, and the Monaco color each sets. */
export const MONACO_THEME_VARIABLES: Array<[EditorStyleVariable, string[]]> = [
  [
    "--cmux-editor-background",
    ["editor.background", "editorGutter.background", "minimap.background", "editorStickyScroll.background"],
  ],
  ["--cmux-editor-foreground", ["editor.foreground"]],
  ["--cmux-editor-line-highlight", ["editor.lineHighlightBackground"]],
  ["--cmux-editor-selection", ["editor.selectionBackground"]],
  ["--cmux-editor-cursor", ["editorCursor.foreground"]],
  ["--cmux-editor-line-number", ["editorLineNumber.foreground"]],
  ["--cmux-editor-line-number-active", ["editorLineNumber.activeForeground"]],
  ["--cmux-editor-indent-guide", ["editorIndentGuide.background1"]],
  ["--cmux-editor-whitespace", ["editorWhitespace.foreground"]],
  ["--cmux-editor-ruler", ["editorRuler.foreground"]],
  ["--cmux-editor-scrollbar", ["scrollbarSlider.background"]],
  ["--cmux-editor-scrollbar-hover", ["scrollbarSlider.hoverBackground", "scrollbarSlider.activeBackground"]],
  [
    "--cmux-editor-widget-background",
    ["editorWidget.background", "editorSuggestWidget.background", "editorHoverWidget.background"],
  ],
  ["--cmux-editor-widget-border", ["editorWidget.border", "editorSuggestWidget.border", "editorHoverWidget.border"]],
];

const SETTINGS_STYLE = "cmux-editor-settings";
const THEME_STYLE = "cmux-editor-theme";

function styleElement(doc: Document, id: string): HTMLStyleElement {
  let style = doc.getElementById(id) as HTMLStyleElement | null;
  if (!style) {
    style = doc.createElement("style");
    style.id = id;
  }
  // Last in <head> each time, so it follows every page stylesheet (Monaco injects its own late).
  doc.head.append(style);
  return style;
}

/**
 * Applies the look in place: the font properties the settings set, then the user's theme.css after
 * them. `themeCSS` undefined keeps the current stylesheet; "" clears it.
 */
export function applyEditorLook(
  settings: EditorSettings,
  appearance: DiffViewerAppearance | undefined,
  themeCSS: string | undefined,
  doc: Document = document,
): void {
  const font = editorFont(settings, appearance);
  const theme = appearance?.themes;
  const lines = [`  --cmux-editor-font-family: ${font.family};`, `  --cmux-editor-font-size: ${font.size}px;`];
  const fg = (value: unknown) =>
    typeof value === "string" && /^#[0-9a-f]{3,8}$/i.test(value.trim()) ? value.trim() : null;
  const lightFg = fg(theme?.light?.foreground);
  const darkFg = fg(theme?.dark?.foreground);
  if (lightFg && darkFg) lines.push(`  --cmux-editor-terminal-foreground: light-dark(${lightFg}, ${darkFg});`);
  const lightSel = fg(theme?.light?.selectionBackground);
  const darkSel = fg(theme?.dark?.selectionBackground);
  if (lightSel && darkSel) lines.push(`  --cmux-editor-terminal-selection: light-dark(${lightSel}, ${darkSel});`);
  styleElement(doc, SETTINGS_STYLE).textContent = `:root {\n${lines.join("\n")}\n}\n`;
  const style = styleElement(doc, THEME_STYLE);
  if (themeCSS !== undefined) style.textContent = themeCSS;
  doc.documentElement.dataset.cmuxEditorToolbar = String(settings.toolbar);
  doc.documentElement.dataset.cmuxEditorStatusBar = String(settings.statusBar);
}

/** The syntax theme names: "terminal" (the terminal palette, as the diff viewer) or Shiki themes. */
export function syntaxThemeNames(value: unknown): { light: string; dark: string } {
  const name = (entry: unknown) => (typeof entry === "string" && /^[a-z0-9-]+$/i.test(entry) ? entry : null);
  if (value && typeof value === "object") {
    const pair = value as { light?: unknown; dark?: unknown };
    return { light: name(pair.light) ?? "terminal", dark: name(pair.dark) ?? name(pair.light) ?? "terminal" };
  }
  const single = name(value) ?? "terminal";
  return { light: single, dark: single };
}
