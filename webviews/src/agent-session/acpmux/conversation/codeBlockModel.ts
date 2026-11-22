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

/// Loads the highlighted card; the page starts it once it has painted (App.tsx).
export const loadHighlightedCode = () => import("./HighlightedCode");
