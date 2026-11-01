// The parts every tool-call block in the transcript shares (an edit's diff, a command's Shell block,
// a call's output): Wrap lines in its header beside Copy, the first `PREVIEW_LINES` lines under a
// fade with "Show all N lines" below, and lines drawn one block each, so a wrapped line hangs under
// its first row.
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { useT } from "../i18n";
import { useBlockWrap, type BlockKind } from "./blockWrap";
import { WrapLines } from "./icons";
import { watchSideways } from "./sideways";
import { SIDEWAYS_SCROLLER_ATTRIBUTE } from "../../../scrollers";

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
      data-fold-toggle=""
      aria-label={t("changes.wrapLines")}
      onClick={toggle}
    >
      <WrapLines />
    </button>
  );
}

/// A block's preview: whether it is long enough to cut (more than `PREVIEW_LINES` lines), and
/// whether the reader opened it. `data-preview` on its body is "cut" or "all", absent when it fits.
/// Each new `reveal` (Find in Chat revealed the block, and a match may be past the cut) opens it.
export function usePreview(lines: number, reveal = 0, overflows = false) {
  const [all, setAll] = useState(reveal > 0);
  const [revealed, setRevealed] = useState(reveal);
  if (reveal !== revealed) {
    setRevealed(reveal);
    if (reveal > 0) setAll(true);
  }
  const long = lines > PREVIEW_LINES || overflows;
  return {
    long,
    cut: long && !all,
    all,
    lines,
    attribute: long ? (all ? "all" : "cut") : undefined,
    toggle: () => setAll((value) => !value),
  };
}

/// "Show all N lines" under a cut block, "Show less" once it is open. A block that draws only the
/// end of a long output counts all of its lines, and opened it draws them all (toolOutput.tsx
/// `previewedOutput`), so N is never the tail's count. Find skips the button's words.
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
      {preview.all ? t("shell.showLess") : t("transcript.showAllLines", { n: preview.lines })}
    </button>
  );
}

/// Keeps the right-edge fade of `ref`'s sideways scrollers current while it is drawn.
export function useSidewaysEdge(ref: RefObject<HTMLElement | null>) {
  useLayoutEffect(() => {
    const node = ref.current;
    return node ? watchSideways(node) : undefined;
  }, [ref]);
}

/// The props of a block body that scrolls sideways itself (a Shell block's, a call output's): its
/// scrollbar is the thin one, with its thumb shown at rest, from the moment it is made (scrollers.ts).
export const SIDEWAYS_SCROLLER = { [SIDEWAYS_SCROLLER_ATTRIBUTE]: "" } as const;

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
