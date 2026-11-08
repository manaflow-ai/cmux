// The highlighted fenced-code card: a Pierre `File` with the pane's syntax theme (a ```diff fence
// is highlighted as a diff). Ported from the agent-pane reference prototype
// (src/conversation/CodeBlock.tsx); CodeBlock.tsx loads it after the page's first frame.
import { cornerAction } from "./cornerActions";
import { useId, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { DIFFS_TAG_NAME, File as PierreFile } from "@pierre/diffs";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, registerAgentDiffTheme } from "../diffTheme";
import { codeUnsafeCSS, cornerUnsafeCSS } from "./highlightedCodeModel";
import { isHighlighted } from "../shikiLanguages";
import { CopyButton } from "./CopyButton";
import { menuPartRef } from "./menuParts";
import { WrapLines } from "./icons";
import { CodeHeader } from "./CodeHeader";
import { codeHeaderClass, useCodeHeaderLook } from "./codeHeaderModel";
import { useT } from "../i18n";
import { MAX_TOKENIZED_LINE } from "./highlightLimits";
import { onHighlightTimeout, paneHighlightPool } from "./highlightPool";
import { PlainCode, PlainCodeLines } from "./StreamingCode";
import { OpenPreview } from "./OpenPreview";
import type { CodeBlockProps } from "./CodeBlock";
import { currentChatMetrics } from "../chatDisplay";
import { highlightWorkerFailed, subscribeHighlightWorker } from "./highlightWorkerState";

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
export function HighlightedCode({
  code,
  lang = "text",
  label,
  actions,
  artifactIdentity,
  artifactRevision,
}: CodeBlockProps) {
  const t = useT();
  const look = useCodeHeaderLook(lang, label);
  const [wrap, setWrap] = useState(false);
  const { host, painted, workerAvailable } = usePierreCode(
    code,
    lang,
    look === "corner" ? cornerUnsafeCSS : codeUnsafeCSS,
    wrap,
  );
  if (!workerAvailable)
    return (
      <PlainCode
        code={code}
        lang={lang}
        label={label}
        actions={actions}
        artifactIdentity={artifactIdentity}
        artifactRevision={artifactRevision}
      />
    );
  return (
    <div className={`cv-codeblock${codeHeaderClass(look)}`} ref={menuPartRef({ code })}>
      <CodeHeader look={look} lang={lang} label={label}>
        <OpenPreview code={code} lang={lang} identity={artifactIdentity} revision={artifactRevision} />
        <button
          type="button"
          className={cornerAction()}
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
      </CodeHeader>
      {/* Keep the text visible until the worker has actually painted. Reserving height alone
          leaves a blank card between the lazy fallback and the worker's first result. */}
      {!painted && (
        <div className="cv-codeblock__body">
          <PlainCodeLines code={code} wrap={wrap} />
        </div>
      )}
      <DiffsHost
        ref={host}
        className="cv-codeblock__body selectable"
        style={{
          ...(!painted ? ({ position: "absolute", inset: "0 0 auto", visibility: "hidden" } as const) : {}),
          minHeight: code.replace(/\n$/, "").split("\n").length * currentChatMetrics().codeLineHeight,
        }}
      />
    </div>
  );
}

/// Pierre's `File` in the pane's syntax theme, painted into `host` in the pane's worker pool: what the
/// fenced card and a read's bare lines (HighlightedLines.tsx) share. `painted` turns true once its lines
/// are on screen; `workerAvailable` false (no pool, a failed worker, a job past its budget) means the
/// caller draws plain lines instead.
export function usePierreCode(code: string, lang: string, unsafeCSS: string, wrap: boolean) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<PierreFile | undefined>(undefined);
  const pool = paneHighlightPool("word-alt", isHighlighted(lang) ? lang : "text");
  const workerFailed = useSyncExternalStore(subscribeHighlightWorker, highlightWorkerFailed, () => false);
  const [painted, setPainted] = useState(false);
  // A highlight job past its budget (highlightWatchdog.ts) draws the card as plain text.
  const name = `snippet-${useId()}`;
  const [tooSlow, setTooSlow] = useState(false);
  const workerAvailable = Boolean(pool?.isWorkingPool()) && !workerFailed && !tooSlow;
  useLayoutEffect(() => onHighlightTimeout(name, () => setTooSlow(true)), [name]);
  useLayoutEffect(() => {
    const el = host.current;
    if (!el || !workerAvailable || highlightWorkerFailed() || !pool?.isWorkingPool()) return;
    setPainted(false);
    registerAgentDiffTheme();
    const file = new PierreFile(
      {
        theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
        themeType: paneThemeType(),
        disableFileHeader: true,
        disableLineNumbers: true,
        overflow: "scroll",
        unsafeCSS,
        tokenizeMaxLineLength: MAX_TOKENIZED_LINE,
        onPostRender: (node, _instance, phase) => {
          if (phase !== "unmount" && node.shadowRoot?.querySelector("[data-line]")) setPainted(true);
        },
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
  }, [lang, unsafeCSS, pool, workerAvailable]);
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
  }, [code, lang, unsafeCSS, pool, wrap, name, workerAvailable]);
  return { host, painted, workerAvailable };
}

/// Pierre's host element (`<diffs-container>`); it attaches its own shadow root.
export const DiffsHost = DIFFS_TAG_NAME as unknown as "div";
