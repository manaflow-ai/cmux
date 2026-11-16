// The highlighted fenced-code card: a Pierre `File` with the pane's syntax theme (a ```diff fence
// is highlighted as a diff). Ported from the agent-pane reference prototype
// (src/conversation/CodeBlock.tsx); CodeBlock.tsx loads it after the page's first frame.
import { cornerAction } from "./cornerActions";
import { useState } from "react";
import { codeUnsafeCSS, cornerUnsafeCSS } from "./highlightedCodeModel";
import { CopyButton } from "./CopyButton";
import { menuPartRef } from "./menuParts";
import { WrapLines } from "./icons";
import { CodeHeader } from "./CodeHeader";
import { codeHeaderClass, useCodeHeaderLook } from "./codeHeaderModel";
import { useT } from "../i18n";
import { PlainCode, PlainCodeLines } from "./StreamingCode";
import { OpenPreview } from "./OpenPreview";
import type { CodeBlockProps } from "./CodeBlock";
import { currentChatMetrics } from "../chatDisplay";
import { DiffsHost, usePierreCode } from "./usePierreCode";

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
    <div className={`cv-codeblock${codeHeaderClass(look)}`} ref={menuPartRef({ code, codeLanguage: lang })}>
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
