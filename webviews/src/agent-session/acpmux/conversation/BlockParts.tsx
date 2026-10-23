// The parts every tool-call block in the transcript shares (an edit's diff, a command's Shell block,
// a call's output): Wrap lines in its header beside Copy, the first `PREVIEW_LINES` lines under a
// fade with "Show all N lines" below (or "Show more" when a few lines wrap to more rows), and lines
// drawn one block each, so a wrapped line hangs under its first row.
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { useT } from "../i18n";
import { useBlockWrap, type BlockKind } from "./blockWrap";
import { WrapLines } from "./icons";
import { watchSideways } from "./sideways";

/// Lines a closed block shows; past them it fades out and offers Show all.
export const PREVIEW_LINES = 8;

/// The header's Wrap lines toggle for a block of `kind` (every block of the kind follows it).
export function WrapButton({ kind, className = "cv-codeblock__action" }: { kind: BlockKind; className?: string }) {
  const t = useT();
  const [wrap, toggle] = useBlockWrap(kind);
  return (
    <button
      type="button"
      className={className}
      aria-pressed={wrap}
      aria-label={t("changes.wrapLines")}
      onClick={toggle}
    >
      <WrapLines />
    </button>
  );
}

/// A block's preview: whether it is long enough to cut (more than `rows` lines, or fewer that
/// `wraps` past as many rows: `useWrapsPast`), and whether the reader opened it. `data-preview`
/// on its body is "cut" or "all", absent when it fits. Each new `reveal` (Find in Chat revealed the
/// block, and a match may be past the cut) opens it.
export function usePreview(lines: number, reveal = 0, wraps = false, rows = PREVIEW_LINES) {
  const [all, setAll] = useState(reveal > 0);
  const [revealed, setRevealed] = useState(reveal);
  if (reveal !== revealed) {
    setRevealed(reveal);
    if (reveal > 0) setAll(true);
  }
  const long = lines > rows || wraps;
  return {
    long,
    /** Cut for its wrapped rows alone: too few lines to count in "Show all N lines". */
    wrapped: long && lines <= rows,
    cut: long && !all,
    all,
    lines,
    attribute: long ? (all ? "all" : "cut") : undefined,
    toggle: () => setAll((value) => !value),
  };
}

/// "Show all N lines" under a cut block ("Show more" under one cut for its wrapped rows), "Show less"
/// once it is open. A block that draws only the end of a long output counts all of its lines, and
/// opened it draws them all (toolOutput.tsx `previewedOutput`), so N is never the tail's count. Find
/// skips the button's words.
export function PreviewMore({ preview }: { preview: ReturnType<typeof usePreview> }) {
  const t = useT();
  if (!preview.long) return null;
  return (
    <button
      type="button"
      className="cv-output-more"
      aria-expanded={preview.all}
      data-find-skip=""
      onClick={preview.toggle}
    >
      {preview.all
        ? t("shell.showLess")
        : preview.wrapped
          ? t("message.more")
          : t("transcript.showAllLines", { n: preview.lines })}
    </button>
  );
}

/// A line longer than the narrowest block's row: only a text with one can wrap.
const WIDE_LINE = /[^\n]{24}/;

/// Whether `ref`'s body, wrapping a text of `lines` lines (no more than the preview shows), still
/// runs past `rows` rows: one long line (a minified log, a one-line JSON result) wraps to
/// many. Its rows are read from the body's own height and line height, never per frame: once each
/// time its text, wrap or line count changes, and as its width changes (a ResizeObserver on this
/// body alone, disconnected when the text changes, it stops wrapping or fits by line count, or it
/// unmounts). A block that is not drawn (a closed call) reads nothing.
export function useWrapsPast(
  ref: RefObject<HTMLElement | null>,
  text: string | undefined,
  wrap: boolean,
  lines: number,
  rows = PREVIEW_LINES,
) {
  const watch = wrap && lines <= rows && Boolean(text && WIDE_LINE.test(text));
  const [past, setPast] = useState(false);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!watch || !node) return;
    const measure = () => setPast(wrappedRows(node) > rows + 0.5);
    measure();
    const Observer = node.ownerDocument.defaultView?.ResizeObserver;
    if (!Observer) return;
    const observer = new Observer(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [ref, watch, text, lines, rows]);
  return watch && past;
}

/// The rows of text in `node`: its content height (the whole of it, even while cut) over its line
/// height, less its padding and the gap between a Shell block's command and output.
function wrappedRows(node: HTMLElement) {
  const style = node.ownerDocument.defaultView!.getComputedStyle(node);
  const line = parseFloat(style.lineHeight);
  if (!(line > 0)) return 0;
  const inset = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
  return (node.scrollHeight - inset - (parseFloat(style.rowGap) || 0)) / line;
}

/// Keeps the right-edge fade of `ref`'s sideways scrollers current while it is drawn.
export function useSidewaysEdge(ref: RefObject<HTMLElement | null>) {
  useLayoutEffect(() => {
    const node = ref.current;
    return node ? watchSideways(node) : undefined;
  }, [ref]);
}

/// The ref a block body watches its right edge through.
export function useSidewaysRef<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useSidewaysEdge(ref);
  return ref;
}

/// The number of lines in `text` (a final newline ends the last line rather than starting one).
export const lineCount = (text: string | undefined) =>
  text ? text.split("\n").length - (text.endsWith("\n") ? 1 : 0) : 0;

/// `text`'s lines, each its own block so a wrapped one hangs under its first row. Each keeps its
/// newline, so the text's copy and Find read it as it was.
export function Lines({ text }: { text: string }) {
  const lines = text.split("\n");
  return lines.map((line, index) => (
    // oxlint-disable-next-line react/no-array-index-key -- a line's place is its identity.
    <span key={index} className="cv-line">
      {index < lines.length - 1 ? `${line}\n` : line}
    </span>
  ));
}
