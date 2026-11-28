import { useLayoutEffect, useRef, type RefObject } from "react";
import { watchSideways } from "./sideways";
import { SIDEWAYS_SCROLLER_ATTRIBUTE } from "../../../scrollers";

/// Lines an output or code card draws whole. Past them the card's body keeps this height and scrolls
/// inside, never behind a Show all button (Leo, 2026-11-12: "this is a
/// really useless show all 9 lines. i think [another chat app] just lets you scroll, straight up?"). The CSS
/// token `--cv-output-box-lines` (outputScrollBox.css) is the same number; a test holds them equal.
export const OUTPUT_BOX_LINES = 24;

/// The class of every such body (outputScrollBox.css): its cap and its inner scroll, which never
/// traps the transcript's wheel (at its edge the wheel chains on to the transcript).
export const OUTPUT_SCROLL_BOX = "cv-scroll-box";

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
