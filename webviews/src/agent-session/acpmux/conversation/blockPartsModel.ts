import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { watchSideways } from "./sideways";
import { SIDEWAYS_SCROLLER_ATTRIBUTE } from "../../../scrollers";

/// Lines a closed block shows; past them it fades out and offers Show all.
export const PREVIEW_LINES = 8;

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

/// A running output can receive thousands of chunks. Keep the visible tail bounded and retain
/// finished chunks by identity so an appended line re-renders only the last chunk. Copy and Find
/// still use the full source string held by their parent.
export const OUTPUT_LINE_WINDOW = 400;
