import { useLayoutEffect, useRef, type RefObject } from "react";
import { watchSideways } from "./sideways";
import { SIDEWAYS_SCROLLER_ATTRIBUTE } from "../../../scrollers";

/// Lines a block's box shows; a longer block scrolls inside it (Leo 2026-11-12: "this is a really
/// useless show all 9 lines").
export const PREVIEW_LINES = 8;

/// A block's preview: whether it is long enough to scroll in its box (more than `PREVIEW_LINES`
/// lines), and whether Find in Chat opened it whole. `data-preview` on its body is "cut" (the box
/// scrolls) or "all", absent when it fits. Each new `reveal` (Find in Chat revealed the block, and a
/// match may be in a long output's head, which is drawn only once opened) opens it.
export function usePreview(lines: number, reveal = 0, overflows = false) {
  const all = reveal > 0;
  const long = lines > PREVIEW_LINES || overflows;
  return {
    long,
    cut: long && !all,
    all,
    lines,
    attribute: long ? (all ? "all" : "cut") : undefined,
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
