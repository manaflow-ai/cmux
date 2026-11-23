// Fenced code inside a transcript. The highlighted card (HighlightedCode.tsx, @pierre/diffs with
// the pane's syntax theme) comes in its own chunk, so the page's first script parses without
// Pierre and Shiki (bd cx-z9kz0); until it has loaded, the card draws as plain text.
import { lazy, Suspense, useMemo, useState, type ReactNode } from "react";
import { isDiagram } from "./codeShape";
import { highlightsCode } from "./highlightLimits";
import { PlainCode, PlainCodeLines } from "./StreamingCode";
import {
  highlightedCodeLoaded,
  highlightedLinesLoaded,
  loadHighlightedCode,
  loadHighlightedLines,
} from "./codeBlockModel";

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
const HighlightedLines = lazy(() => loadHighlightedLines().then((module) => ({ default: module.HighlightedLines })));

/// A file's bare lines (a read's peek, FileResultCard.tsx), highlighted by `path`'s language in the
/// same chunk as the fenced card; plain while it loads and past the highlight limits.
export function CodeLines({ code, path }: { code: string; path: string }) {
  // As CodeBlock's: read once, so a card never mounts twice.
  const [Loaded] = useState(() => highlightedLinesLoaded()?.HighlightedLines);
  const highlights = highlightsCode(code);
  const plain = (
    <div className="cv-filepeek__lines" data-highlight-pending={highlights ? "" : undefined}>
      <PlainCodeLines code={code} />
    </div>
  );
  if (!highlights) return plain;
  if (Loaded) return <Loaded code={code} path={path} />;
  return (
    <Suspense fallback={plain}>
      <HighlightedLines code={code} path={path} />
    </Suspense>
  );
}

/**
 * Fenced code card. A fence over the highlight limits (highlightLimits.ts) and an unlabeled
 * box-drawing diagram (codeShape.ts) draw as plain monospace text; any other is highlighted
 * (`HighlightedCode`), plain until its chunk has loaded.
 */
export function CodeBlock(props: CodeBlockProps) {
  const lang = props.lang ?? "text";
  const diagram = useMemo(() => isDiagram(props.code, lang), [props.code, lang]);
  // Read once per card: a card first drawn after the chunk loaded draws it directly, with no plain
  // fallback frame; one drawn before keeps its lazy element, so it never mounts twice.
  const [Loaded] = useState(() => highlightedCodeLoaded()?.HighlightedCode);
  const highlights = highlightsCode(props.code) && !diagram;
  const plain = (
    <PlainCode
      code={props.code}
      lang={lang}
      label={props.label}
      actions={props.actions}
      artifactIdentity={props.artifactIdentity}
      artifactRevision={props.artifactRevision}
      highlightPending={highlights}
    />
  );
  if (!highlights) return plain;
  if (Loaded) return <Loaded {...props} />;
  return (
    <Suspense fallback={plain}>
      <HighlightedCode {...props} />
    </Suspense>
  );
}
