import { translate, type Translate } from "../i18n";

/// Header label shown for a fence language: its name, which no language translates.
// l10n-allow: programming language names
const LANG_LABELS: Record<string, string> = {
  python: "Python",
  py: "Python",
  json: "JSON",
  diff: "Diff",
  ts: "TypeScript",
  typescript: "TypeScript",
  js: "JavaScript",
  javascript: "JavaScript",
  swift: "Swift",
  sh: "Shell",
  bash: "Shell",
  html: "HTML",
  htm: "HTML",
  svg: "SVG",
  markdown: "Markdown",
  md: "Markdown",
};

export function languageLabel(lang: string, t: Translate = translate) {
  return lang === "text" || lang === "txt" ? t("code.plainText") : (LANG_LABELS[lang] ?? lang);
}

type HighlightedCodeModule = typeof import("./HighlightedCode");
let loading: Promise<HighlightedCodeModule> | undefined;
let loaded: HighlightedCodeModule | undefined;

/// Loads the highlighted card, once; the page starts it once it has painted (App.tsx), or as the
/// bundle starts when a relaunch's copy shows highlighted code (chatSnapshot/live.ts).
export const loadHighlightedCode = (): Promise<HighlightedCodeModule> =>
  (loading ??= import("./HighlightedCode").then(
    (module) => (loaded = module),
    (error: unknown) => {
      // A chunk that failed to load is asked for again by the next card.
      loading = undefined;
      throw error;
    },
  ));

/// The highlighted card's module once it has loaded: a card first drawn after that draws it at once,
/// with no plain fallback frame (CodeBlock.tsx).
export const highlightedCodeLoaded = (): HighlightedCodeModule | undefined => loaded;

type HighlightedLinesModule = typeof import("./HighlightedLines");
let linesLoading: Promise<HighlightedLinesModule> | undefined;
let linesLoaded: HighlightedLinesModule | undefined;

/// Loads a read file's highlighted lines (CodeBlock.tsx `CodeLines`), once; as the fenced card's.
export const loadHighlightedLines = (): Promise<HighlightedLinesModule> =>
  (linesLoading ??= import("./HighlightedLines").then(
    (module) => (linesLoaded = module),
    (error: unknown) => {
      linesLoading = undefined;
      throw error;
    },
  ));

/// A read file's highlighted lines module once it has loaded.
export const highlightedLinesLoaded = (): HighlightedLinesModule | undefined => linesLoaded;
