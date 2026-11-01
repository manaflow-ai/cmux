// Fenced code inside a transcript. The highlighted card (HighlightedCode.tsx, @pierre/diffs with
// the pane's syntax theme) comes in its own chunk, so the page's first script parses without
// Pierre and Shiki (bd cx-z9kz0); until it has loaded, the card draws as plain text.
import { lazy, Suspense, type ReactNode } from "react";
import { translate, type Translate } from "../i18n";
import { highlightsCode } from "./highlightLimits";
import { PlainCode } from "./StreamingCode";

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

export type CodeBlockProps = {
  code: string;
  actions?: ReactNode;
  /** Fence language (`python`, `json`, `diff`, `text`, …). */
  lang?: string;
  /** Header label; defaults to the language's display name. */
  label?: string;
};

/// Loads the highlighted card; the page starts it once it has painted (App.tsx).
export const loadHighlightedCode = () => import("./HighlightedCode");
const HighlightedCode = lazy(() => loadHighlightedCode().then((module) => ({ default: module.HighlightedCode })));

/**
 * Fenced code card. A fence over the highlight limits (highlightLimits.ts) draws as plain
 * monospace text; any other is highlighted (`HighlightedCode`), plain until its chunk has loaded.
 */
export function CodeBlock(props: CodeBlockProps) {
  const plain = <PlainCode code={props.code} lang={props.lang ?? "text"} actions={props.actions} />;
  return highlightsCode(props.code) ? (
    <Suspense fallback={plain}>
      <HighlightedCode {...props} />
    </Suspense>
  ) : (
    plain
  );
}
