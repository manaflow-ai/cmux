// Fenced code inside a transcript. The highlighted card (HighlightedCode.tsx, @pierre/diffs with
// the pane's syntax theme) comes in its own chunk, so the page's first script parses without
// Pierre and Shiki (bd cx-z9kz0); until it has loaded, the card draws as plain text.
import { lazy, Suspense, useMemo, type ReactNode } from "react";
import { isDiagram } from "./codeShape";
import { highlightsCode } from "./highlightLimits";
import { PlainCode } from "./StreamingCode";
import { loadHighlightedCode } from "./codeBlockModel";

export type CodeBlockProps = {
  code: string;
  actions?: ReactNode;
  /** Fence language (`python`, `json`, `diff`, `text`, …). */
  lang?: string;
  /** Header label; defaults to the language's display name. */
  label?: string;
  /** Stable identity and source revision for an artifact in a streaming assistant row. */
  artifactIdentity?: string;
  artifactRevision?: number;
};

const HighlightedCode = lazy(() => loadHighlightedCode().then((module) => ({ default: module.HighlightedCode })));

/**
 * Fenced code card. A fence over the highlight limits (highlightLimits.ts) and an unlabeled
 * box-drawing diagram (codeShape.ts) draw as plain monospace text; any other is highlighted
 * (`HighlightedCode`), plain until its chunk has loaded.
 */
export function CodeBlock(props: CodeBlockProps) {
  const lang = props.lang ?? "text";
  const diagram = useMemo(() => isDiagram(props.code, lang), [props.code, lang]);
  const plain = (
    <PlainCode
      code={props.code}
      lang={lang}
      label={props.label}
      actions={props.actions}
      artifactIdentity={props.artifactIdentity}
      artifactRevision={props.artifactRevision}
    />
  );
  return highlightsCode(props.code) && !diagram ? (
    <Suspense fallback={plain}>
      <HighlightedCode {...props} />
    </Suspense>
  ) : (
    plain
  );
}
