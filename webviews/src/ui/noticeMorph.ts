// A toast that changes in place (NoticeQueue.promise: working, then success or error) keeps its
// slot and moves as one: its box goes from the old size to the new over one standard step, so the
// card never jumps and nothing pops in (Leo 2026-11-04: "we move all our affected, possibly
// affected elements in the cohesive way"). Inside the stacked deck the deck owns the card's height
// (NoticeDeck.tsx) and its width is the deck's, so this only moves what the deck does not.
//
// Cost: one layout read per change of the card's state or text, on that card only, never per
// frame or per toast in the stack. One finite Web Animation that ends on its own; the next change
// and unmount cancel it. Motion off, a hidden page or Reduce Motion (motionMode): the new size in
// one frame.
import { type RefObject, useLayoutEffect, useRef } from "react";
import { MOTION_EASE_OUT, MOTION_MS } from "../motion/scale.generated";
import { motionMode } from "./motion/motionMode";

/** While the box moves the card carries this; one-line text holds its line (notice.css). */
export const NOTICE_MORPHING_ATTRIBUTE = "data-morphing";

export function useNoticeMorph(ref: RefObject<HTMLElement | null>, key: string | undefined): void {
  const last = useRef<{ key: string; width: number; height: number } | undefined>(undefined);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element || key === undefined) return;
    const box = element.getBoundingClientRect();
    const before = last.current;
    last.current = { key, width: box.width, height: box.height };
    if (!before || before.key === key) return;
    const inDeck = element.closest(".ui-notice-deck-card") !== null;
    const widthMoves = Math.abs(before.width - box.width) >= 0.5;
    const heightMoves = !inDeck && Math.abs(before.height - box.height) >= 0.5;
    if (!widthMoves && !heightMoves) return;
    if (motionMode(element.ownerDocument, element) !== "full" || typeof element.animate !== "function") return;
    const from: Keyframe = {};
    const to: Keyframe = {};
    if (widthMoves) {
      from.width = `${before.width}px`;
      to.width = `${box.width}px`;
    }
    if (heightMoves) {
      from.height = `${before.height}px`;
      to.height = `${box.height}px`;
    }
    // A one-line toast stays one line while its box moves; one whose height changes clips instead.
    element.setAttribute(NOTICE_MORPHING_ATTRIBUTE, heightMoves ? "clip" : "line");
    const animation = element.animate([from, to], { duration: MOTION_MS.standard, easing: MOTION_EASE_OUT });
    const done = () => element.removeAttribute(NOTICE_MORPHING_ATTRIBUTE);
    animation.addEventListener("finish", done);
    return () => {
      animation.removeEventListener("finish", done);
      animation.cancel();
      done();
    };
  }, [ref, key]);
}
