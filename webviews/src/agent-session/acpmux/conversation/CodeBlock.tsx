// Fenced code inside a transcript, rendered by @pierre/diffs `File` with the pane's
// syntax theme (a ```diff fence is highlighted as a diff). Ported from
// the agent-pane reference prototype (src/conversation/CodeBlock.tsx).
import { useId, useLayoutEffect, useRef, useState } from "react";
import { DIFFS_TAG_NAME, File as PierreFile } from "@pierre/diffs";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { copyText } from "./clipboard";
import { CodeBrackets, Copy, WrapLines } from "./icons";
import { translate, type Translate, useT } from "../i18n";
import { highlightsCode, MAX_TOKENIZED_LINE } from "./highlightLimits";
import { onHighlightTimeout, paneHighlightPool } from "./highlightPool";
import { PlainCode } from "./StreamingCode";

/// Pierre paints its own lines; they are transparent so the card's fill shows through.
const codeUnsafeCSS = `${diffUnsafeCSS}
:host {
  --diffs-dark-bg: transparent;
  --diffs-light-bg: transparent;
  --diffs-font-size: 12px;
  --diffs-line-height: 20px;
  background: transparent;
}
[data-line] > span { top: 0; }
pre, code, [data-code], [data-content], [data-line] { background: transparent !important; --diffs-line-bg: transparent; }
`;

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
};

export function languageLabel(lang: string, t: Translate = translate) {
  return lang === "text" || lang === "txt" ? t("code.plainText") : (LANG_LABELS[lang] ?? lang);
}

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () => (document.documentElement.dataset.theme === "light" ? "light" : "dark");

export type CodeBlockProps = {
  code: string;
  /** Fence language (`python`, `json`, `diff`, `text`, …). */
  lang?: string;
  /** Header label; defaults to the language's display name. */
  label?: string;
};

/**
 * Fenced code card. A fence over the highlight limits (highlightLimits.ts) draws as plain
 * monospace text; any other is highlighted (`HighlightedCode`).
 */
export function CodeBlock(props: CodeBlockProps) {
  return highlightsCode(props.code) ? <HighlightedCode {...props} /> : <PlainCode code={props.code} lang={props.lang ?? "text"} />;
}

/**
 * Fenced code card: language label with wrap and copy over a Pierre `File`, highlighted in the
 * pane's worker pool (highlightPool.ts) where the page has one.
 *
 * One File lives as long as the card. A streaming fence grows on every chunk, so new text
 * re-renders the same instance instead of building another; a theme switch on the page
 * (applyAgentTheme sets `data-theme`) changes its syntax colors in place.
 */
function HighlightedCode({ code, lang = "text", label }: CodeBlockProps) {
  const t = useT();
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<PierreFile | undefined>(undefined);
  const [wrap, setWrap] = useState(false);
  const [copied, setCopied] = useState(false);
  // A highlight job past its budget (highlightWatchdog.ts) draws the card as plain text.
  const name = `snippet-${useId()}`;
  const [tooSlow, setTooSlow] = useState(false);
  useLayoutEffect(() => onHighlightTimeout(name, () => setTooSlow(true)), [name]);
  useLayoutEffect(() => {
    const el = host.current;
    if (!el) return;
    registerAgentDiffTheme();
    const file = new PierreFile(
      {
        theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
        themeType: paneThemeType(),
        disableFileHeader: true,
        disableLineNumbers: true,
        overflow: "scroll",
        unsafeCSS: codeUnsafeCSS,
        tokenizeMaxLineLength: MAX_TOKENIZED_LINE,
      },
      paneHighlightPool(),
      // React owns the host element: Pierre must not remove it on cleanUp.
      true,
    );
    view.current = file;
    const theme = new MutationObserver(() => file.setThemeType(paneThemeType()));
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      theme.disconnect();
      view.current = undefined;
      file.cleanUp();
      el.shadowRoot?.replaceChildren();
    };
  }, []);
  useLayoutEffect(() => {
    const el = host.current;
    const file = view.current;
    if (!el || !file) return;
    file.setOptions({ ...file.options, overflow: wrap ? "wrap" : "scroll" });
    // Shiki throws for a language the bundle does not ship; those draw as plain text.
    file.render({
      fileContainer: el,
      file: { name, contents: code, lang: (isHighlighted(lang) ? lang : "text") as never },
    });
  }, [code, lang, wrap, name]);
  if (tooSlow) return <PlainCode code={code} lang={lang} />;
  return (
    <div className="cv-codeblock">
      <div className="cv-codeblock__header">
        <CodeBrackets size={17} strokeWidth={1.2} />
        <span>{label ?? languageLabel(lang, t)}</span>
        <span className="cv-codeblock__actions">
          <button
            type="button"
            className="cv-codeblock__action"
            aria-pressed={wrap}
            aria-label={t("changes.wrapLines")}
            title={t("changes.wrapLines")}
            onClick={() => setWrap((value) => !value)}
          >
            <WrapLines />
          </button>
          <button
            type="button"
            className="cv-codeblock__action"
            aria-label={copied ? t("code.copied") : t("code.copy")}
            title={copied ? t("code.copied") : t("code.copy")}
            onClick={() => void copyText(code).then(() => setCopied(true))}
          >
            <Copy />
          </button>
        </span>
      </div>
      <DiffsHost ref={host} className="cv-codeblock__body selectable" />
    </div>
  );
}

/// Pierre's host element (`<diffs-container>`); it attaches its own shadow root.
const DiffsHost = DIFFS_TAG_NAME as unknown as "div";
