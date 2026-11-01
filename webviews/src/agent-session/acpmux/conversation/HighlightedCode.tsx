// The highlighted fenced-code card: a Pierre `File` with the pane's syntax theme (a ```diff fence
// is highlighted as a diff). Ported from the agent-pane reference prototype
// (src/conversation/CodeBlock.tsx); CodeBlock.tsx loads it after the page's first frame.
import { useId, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { DIFFS_TAG_NAME, File as PierreFile } from "@pierre/diffs";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { CopyButton } from "./CopyButton";
import { menuPartRef } from "./menuParts";
import { CodeBrackets, WrapLines } from "./icons";
import { useT } from "../i18n";
import { MAX_TOKENIZED_LINE } from "./highlightLimits";
import { onHighlightTimeout, paneHighlightPool } from "./highlightPool";
import { PlainCode } from "./StreamingCode";
import { OpenPreview } from "./OpenPreview";
import { languageLabel, type CodeBlockProps } from "./CodeBlock";
import { currentChatMetrics } from "../chatDisplay";
import { highlightWorkerFailed, subscribeHighlightWorker } from "./highlightWorkerState";

/// Pierre's line height: a line of the card's body.
const LINE_HEIGHT = 20;

/// Pierre paints its own lines; they are transparent so the card's fill shows through.
const codeUnsafeCSS = `${diffUnsafeCSS}
:host {
  --diffs-dark-bg: transparent;
  --diffs-light-bg: transparent;
  --diffs-font-family: var(--cv-mono, var(--cmux-diff-code-font-family, "SF Mono", ui-monospace, Menlo, monospace));
  --diffs-font-size: var(--cv-codeblock-size, 12px);
  --diffs-line-height: var(--cv-codeblock-line-height, ${LINE_HEIGHT}px);
  background: transparent;
}
[data-line] > span { top: 0; }
pre, code, [data-code], [data-content], [data-line] { background: transparent !important; --diffs-line-bg: transparent; }
/* Pierre keeps a strip for its horizontal scrollbar under the lines at all times
   (--diffs-scrollbar-gutter: 6px in WebKit, 0 where scrollbars overlay). It hangs into the card's
   bottom padding instead, so the card is as tall as its lines in every engine, as the plain card
   it replaces is (StreamingCode.tsx), and the text under a closing fence does not move. */
pre[data-file] { display: flow-root; }
[data-code] { margin-bottom: calc(-1 * var(--diffs-scrollbar-gutter, 0px)); }
`;

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () => (document.documentElement.dataset.theme === "light" ? "light" : "dark");

/**
 * Fenced code card: language label with wrap and copy over a Pierre `File`, highlighted in the
 * pane's worker pool (highlightPool.ts) where the page has one.
 *
 * One File lives as long as the card. A streaming fence grows on every chunk, so new text
 * re-renders the same instance instead of building another; a theme switch on the page
 * (applyAgentTheme sets `data-theme`) changes its syntax colors in place.
 */
export function HighlightedCode({ code, lang = "text", label, actions }: CodeBlockProps) {
  const t = useT();
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<PierreFile | undefined>(undefined);
  const pool = paneHighlightPool("word-alt", isHighlighted(lang) ? lang : "text");
  const workerFailed = useSyncExternalStore(subscribeHighlightWorker, highlightWorkerFailed, () => false);
  const [wrap, setWrap] = useState(false);
  // A highlight job past its budget (highlightWatchdog.ts) draws the card as plain text.
  const name = `snippet-${useId()}`;
  const [tooSlow, setTooSlow] = useState(false);
  const workerAvailable = Boolean(pool?.isWorkingPool()) && !workerFailed && !tooSlow;
  useLayoutEffect(() => onHighlightTimeout(name, () => setTooSlow(true)), [name]);
  useLayoutEffect(() => {
    const el = host.current;
    if (!el || !workerAvailable || highlightWorkerFailed() || !pool?.isWorkingPool()) return;
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
      pool,
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
  }, [lang, pool, workerAvailable]);
  useLayoutEffect(() => {
    const el = host.current;
    const file = view.current;
    if (!el || !file || !workerAvailable || highlightWorkerFailed() || !pool?.isWorkingPool()) return;
    file.setOptions({ ...file.options, overflow: wrap ? "wrap" : "scroll" });
    // Shiki throws for a language the bundle does not ship; those draw as plain text.
    file.render({
      fileContainer: el,
      file: { name, contents: code, lang: (isHighlighted(lang) ? lang : "text") as never },
    });
  }, [code, lang, pool, wrap, name, workerAvailable]);
  if (!workerAvailable) return <PlainCode code={code} lang={lang} actions={actions} />;
  return (
    <div className="cv-codeblock" ref={menuPartRef({ code })}>
      <div className="cv-codeblock__header">
        <CodeBrackets size={17} strokeWidth={1.2} />
        <span>{label ?? languageLabel(lang, t)}</span>
        <span className="cv-codeblock__actions">
          <OpenPreview code={code} lang={lang} />
          <button
            type="button"
            className="cv-codeblock__action"
            aria-pressed={wrap}
            data-fold-toggle=""
            aria-label={t("changes.wrapLines")}
            title={t("changes.wrapLines")}
            onClick={() => setWrap((value) => !value)}
          >
            <WrapLines />
          </button>
          <CopyButton text={code} label={t("code.copy")} />
          {actions}
        </span>
      </div>
      {/* Pierre paints the lines once the highlight worker answers; until then the body keeps the
          plain card's height, so the text under the card does not move up and back (cx-wdenv). */}
      <DiffsHost
        ref={host}
        className="cv-codeblock__body selectable"
        style={{
          minHeight: code.replace(/\n$/, "").split("\n").length * currentChatMetrics().codeLineHeight,
        }}
      />
    </div>
  );
}

/// Pierre's host element (`<diffs-container>`); it attaches its own shadow root.
const DiffsHost = DIFFS_TAG_NAME as unknown as "div";
