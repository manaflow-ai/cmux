// The markdown editor's look: one typed set of CSS custom properties (`--cmux-md-*`), each with a
// default, fed from the `markdown` section of cmux.json (the host passes it in the page config and
// re-sends it on change), then the user stylesheet `<cmux.json dir>/markdown/theme.css` applied last.
// Cascade: the defaults (styles.css, `:where(:root)`, no specificity) < settings (`:root`) <
// theme.css (after it). Fonts follow the app by default: the body uses the system UI font as every
// page does (pageBase.css), code the terminal font the host's appearance sets
// (`--cmux-diff-code-font-family`, appearance.ts), as in the diff viewer.
import type { DiffViewerAppearance } from "../../appearance";

/** Every `--cmux-md-*` property and its default. styles.css declares the same defaults. */
export const MARKDOWN_STYLE_DEFAULTS = {
  "--cmux-md-font-family": '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif',
  "--cmux-md-font-size": "16px",
  "--cmux-md-font-weight": "400",
  "--cmux-md-line-height": "1.6",
  "--cmux-md-text-color": "var(--page-text)",
  "--cmux-md-muted-color": "var(--page-text-2)",
  "--cmux-md-faint-color": "var(--page-text-3)",
  "--cmux-md-border-color": "var(--page-separator)",
  "--cmux-md-heading-font-family": "var(--cmux-md-font-family)",
  "--cmux-md-heading-weight": "600",
  "--cmux-md-heading-line-height": "1.25",
  "--cmux-md-heading-color": "var(--cmux-md-text-color)",
  "--cmux-md-heading-rule": "1px solid var(--cmux-md-border-color)",
  "--cmux-md-h1-size": "2em",
  "--cmux-md-h2-size": "1.5em",
  "--cmux-md-h3-size": "1.25em",
  "--cmux-md-h4-size": "1.1em",
  "--cmux-md-h5-size": "1em",
  "--cmux-md-h6-size": "0.9em",
  "--cmux-md-code-font-family": "var(--cmux-diff-code-font-family, ui-monospace, SFMono-Regular, Menlo, monospace)",
  "--cmux-md-code-inline-size": "0.88em",
  "--cmux-md-code-block-size": "14px",
  "--cmux-md-code-line-height": "1.55",
  "--cmux-md-code-background": "color-mix(in srgb, var(--page-text) 5%, transparent)",
  "--cmux-md-code-radius": "6px",
  "--cmux-md-content-width": "72ch",
  "--cmux-md-page-padding": "32px",
  "--cmux-md-paragraph-spacing": "1em",
  "--cmux-md-list-spacing": "0.25em",
  "--cmux-md-list-indent": "1.8em",
  "--cmux-md-link-color": "light-dark(#0b63c7, #6cb0ff)",
  "--cmux-md-quote-color": "var(--cmux-md-muted-color)",
  "--cmux-md-quote-border": "3px solid var(--cmux-md-border-color)",
  "--cmux-md-table-border": "1px solid var(--cmux-md-border-color)",
  "--cmux-md-table-header-background": "var(--cmux-md-code-background)",
  "--cmux-md-task-checked-color": "var(--cmux-md-link-color)",
  "--cmux-md-selection-color": "color-mix(in srgb, var(--cmux-md-link-color) 28%, transparent)",
  "--cmux-md-caret-color": "var(--cmux-md-text-color)",
  "--cmux-md-footnote-size": "0.9em",
  "--cmux-md-superscript-size": "0.75em",
  "--cmux-md-ui-font-size": "13px",
  "--cmux-md-toolbar-font-size": "12px",
  "--cmux-md-accent-background": "color-mix(in srgb, var(--page-text) 8%, transparent)",
  "--cmux-md-banner-background": "light-dark(rgb(255 196 0 / 0.16), rgb(255 196 0 / 0.12))",
  "--cmux-md-error-color": "light-dark(#b42318, #ff8a80)",
  "--cmux-md-link-broken-color": "var(--cmux-md-error-color)",
  "--cmux-md-popover-background": "var(--page-elevated)",
  "--cmux-md-popover-shadow": "0 6px 24px rgb(0 0 0 / 0.18)",
  "--cmux-md-popover-font-size": "12px",
} as const;

export type MarkdownStyleVariable = keyof typeof MARKDOWN_STYLE_DEFAULTS;

/** A color for both schemes, or one per scheme. */
export type MarkdownColor = string | { light?: string; dark?: string };

/**
 * The `markdown` section of cmux.json. Every key is optional; a missing or invalid one keeps its
 * default. Numbers are pixels where a length is meant (sizes, width, padding) and unitless for
 * line heights and weights; strings are CSS values.
 */
export interface MarkdownSettings {
  /** `markdown.defaultMode`: the mode a file opens in, `"rich"` (default) or `"source"`. */
  defaultMode?: "rich" | "source";
  /** `markdown.toolbar`: show the toolbar (file, save status, mode switch). Default true. */
  toolbar?: boolean;
  font?: { family?: string; size?: number | string; weight?: number | string; lineHeight?: number | string };
  headings?: {
    family?: string;
    weight?: number | string;
    lineHeight?: number | string;
    /** Each level `scale` times the next: h5 is 1em, h1 `scale^4`, h6 `1/scale`. */
    scale?: number;
    /** h1 through h6 in em; wins over `scale`. */
    sizes?: Array<number | string>;
    color?: MarkdownColor;
  };
  code?: {
    family?: string;
    /** Inline code, relative to the text (em) or a CSS size. */
    inlineSize?: number | string;
    /** Code blocks, in pixels or a CSS size. */
    blockSize?: number | string;
    lineHeight?: number | string;
    background?: MarkdownColor;
    /** `"terminal"` (default: the terminal palette, as the diff viewer), a Shiki theme name, or one per scheme. */
    theme?: string | { light?: string; dark?: string };
  };
  layout?: { maxWidth?: number | string; padding?: number | string };
  spacing?: { paragraph?: number | string; list?: number | string; listIndent?: number | string };
  colors?: {
    text?: MarkdownColor;
    link?: MarkdownColor;
    quote?: MarkdownColor;
    quoteBorder?: MarkdownColor;
    tableBorder?: MarkdownColor;
    tableHeader?: MarkdownColor;
    selection?: MarkdownColor;
    caret?: MarkdownColor;
    taskChecked?: MarkdownColor;
  };
}

/** A CSS value the page accepts from settings: no rule or tag breakouts, not empty, short. */
export function cssValue(value: unknown): string | null {
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : null;
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text || text.length > 300 || /[;{}<>\\]|\/\*/.test(text)) return null;
  return text;
}

const length = (value: unknown, unit = "px"): string | null =>
  typeof value === "number" ? (Number.isFinite(value) && value >= 0 ? `${value}${unit}` : null) : cssValue(value);

function color(value: unknown): string | null {
  if (value && typeof value === "object") {
    const pair = value as { light?: unknown; dark?: unknown };
    const light = cssValue(pair.light);
    const dark = cssValue(pair.dark);
    if (light && dark) return `light-dark(${light}, ${dark})`;
    return light ?? dark;
  }
  return cssValue(value);
}

const object = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

/** The `--cmux-md-*` values the settings set (only those; the rest keep their defaults). */
export function markdownStyleVariables(settings: unknown): Partial<Record<MarkdownStyleVariable, string>> {
  const root = object(settings);
  const font = object(root.font);
  const headings = object(root.headings);
  const code = object(root.code);
  const layout = object(root.layout);
  const spacing = object(root.spacing);
  const colors = object(root.colors);
  const out: Partial<Record<MarkdownStyleVariable, string>> = {};
  const put = (name: MarkdownStyleVariable, value: string | null) => {
    if (value !== null) out[name] = value;
  };
  put("--cmux-md-font-family", cssValue(font.family));
  put("--cmux-md-font-size", length(font.size));
  put("--cmux-md-font-weight", cssValue(font.weight));
  put("--cmux-md-line-height", cssValue(font.lineHeight));
  put("--cmux-md-heading-font-family", cssValue(headings.family));
  put("--cmux-md-heading-weight", cssValue(headings.weight));
  put("--cmux-md-heading-line-height", cssValue(headings.lineHeight));
  put("--cmux-md-heading-color", color(headings.color));
  const levels = [
    "--cmux-md-h1-size",
    "--cmux-md-h2-size",
    "--cmux-md-h3-size",
    "--cmux-md-h4-size",
    "--cmux-md-h5-size",
    "--cmux-md-h6-size",
  ] as const;
  const scale =
    typeof headings.scale === "number" && headings.scale >= 1 && headings.scale <= 3 ? headings.scale : null;
  levels.forEach((name, index) => {
    const sizes = Array.isArray(headings.sizes) ? headings.sizes : [];
    const explicit = sizes[index] !== undefined ? length(sizes[index], "em") : null;
    const scaled = scale ? `${Number((scale ** (4 - index)).toFixed(3))}em` : null;
    put(name, explicit ?? scaled);
  });
  put("--cmux-md-code-font-family", cssValue(code.family));
  put("--cmux-md-code-inline-size", length(code.inlineSize, "em"));
  put("--cmux-md-code-block-size", length(code.blockSize));
  put("--cmux-md-code-line-height", cssValue(code.lineHeight));
  put("--cmux-md-code-background", color(code.background));
  put("--cmux-md-content-width", length(layout.maxWidth));
  put("--cmux-md-page-padding", length(layout.padding));
  put("--cmux-md-paragraph-spacing", length(spacing.paragraph));
  put("--cmux-md-list-spacing", length(spacing.list));
  put("--cmux-md-list-indent", length(spacing.listIndent));
  put("--cmux-md-text-color", color(colors.text));
  put("--cmux-md-link-color", color(colors.link));
  put("--cmux-md-quote-color", color(colors.quote));
  const quoteBorder = color(colors.quoteBorder);
  if (quoteBorder) put("--cmux-md-quote-border", `3px solid ${quoteBorder}`);
  const tableBorder = color(colors.tableBorder);
  if (tableBorder) put("--cmux-md-table-border", `1px solid ${tableBorder}`);
  put("--cmux-md-table-header-background", color(colors.tableHeader));
  put("--cmux-md-selection-color", color(colors.selection));
  put("--cmux-md-caret-color", color(colors.caret));
  put("--cmux-md-task-checked-color", color(colors.taskChecked));
  return out;
}

/** The settings' default mode and toolbar flag. */
export function markdownBehavior(settings: unknown): { defaultMode: "rich" | "source"; toolbar: boolean } {
  const root = object(settings);
  return { defaultMode: root.defaultMode === "source" ? "source" : "rich", toolbar: root.toolbar !== false };
}

/** The code theme setting: `"terminal"` or Shiki theme names per scheme. */
export function markdownCodeTheme(settings: unknown): { light: string; dark: string } {
  const theme = object(settings).code ? object(object(settings).code).theme : undefined;
  const name = (value: unknown) => (typeof value === "string" && /^[a-z0-9-]+$/i.test(value) ? value : null);
  if (theme && typeof theme === "object") {
    const pair = theme as { light?: unknown; dark?: unknown };
    return { light: name(pair.light) ?? "terminal", dark: name(pair.dark) ?? name(pair.light) ?? "terminal" };
  }
  const single = name(theme) ?? "terminal";
  return { light: single, dark: single };
}

const SETTINGS_STYLE = "cmux-md-settings";
const THEME_STYLE = "cmux-md-theme";

function styleElement(doc: Document, id: string): HTMLStyleElement {
  let style = doc.getElementById(id) as HTMLStyleElement | null;
  if (!style) {
    style = doc.createElement("style");
    style.id = id;
  }
  // Last in <head> each time, so it follows every page stylesheet (dev injects styles late).
  doc.head.append(style);
  return style;
}

/**
 * Applies a look to the page in place (no reload): the settings' `--cmux-md-*` values, then the
 * user's theme.css after them. `themeCSS` undefined keeps the current stylesheet; "" clears it.
 */
export function applyMarkdownLook(settings: unknown, themeCSS: string | undefined, doc: Document = document): void {
  const variables = markdownStyleVariables(settings);
  const body = Object.entries(variables)
    .map(([name, value]) => `  ${name}: ${value};`)
    .join("\n");
  styleElement(doc, SETTINGS_STYLE).textContent = body ? `:root {\n${body}\n}\n` : "";
  const theme = styleElement(doc, THEME_STYLE);
  if (themeCSS !== undefined) theme.textContent = themeCSS;
  doc.documentElement.dataset.cmuxMdToolbar = String(markdownBehavior(settings).toolbar);
}

/** The store surface `bindMarkdownLook` follows (MarkdownStore). */
export interface LookSource {
  subscribe(listener: () => void): () => void;
  getState(): {
    phase: string;
    look: { settings: unknown; themeCSS: string | undefined; appearance: DiffViewerAppearance | undefined };
  };
}

/**
 * Applies the store's look to the page whenever it changes, in place: the CSS variables and
 * theme.css at once, the terminal appearance through `appearance`, and a code theme change (not the
 * first one, which the highlighter starts with) through `codeTheme`. Returns the unsubscribe.
 */
export function bindMarkdownLook(
  store: LookSource,
  apply: {
    appearance?(appearance: DiffViewerAppearance): void;
    codeTheme?(names: { light: string; dark: string }, appearance: DiffViewerAppearance | undefined): void;
  } = {},
  doc: Document = document,
): () => void {
  let applied: unknown = null;
  let codeKey = "";
  const update = () => {
    const { look, phase } = store.getState();
    if (phase !== "ready" || look === applied) return;
    applied = look;
    if (look.appearance) apply.appearance?.(look.appearance);
    applyMarkdownLook(look.settings, look.themeCSS ?? "", doc);
    const names = markdownCodeTheme(look.settings);
    const key = JSON.stringify([names, look.appearance ?? null]);
    if (key === codeKey) return;
    const first = codeKey === "";
    codeKey = key;
    if (!first) apply.codeTheme?.(names, look.appearance);
  };
  update();
  return store.subscribe(update);
}
