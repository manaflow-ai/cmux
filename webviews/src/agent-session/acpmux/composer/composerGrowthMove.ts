// The composer's own growth, declared by the code that makes it (schemas/layout-motion/contract.json
// `composer-growth`): the field gaining or losing a line (fieldGrowth.ts), and the attachment row coming
// or going above it (ComposerBox.tsx). Leo, 2026-11-18: "the things that move we only expect at certain
// times". An edit that places an attachment grows the box in its own frame (composer-attach-no-jump.test.ts);
// a paste, a drop, a capture the host answers and a draft read back all arrive that way, by no key, so
// nothing else declares them.
//
// The declaration is as short as the move: until the field's motion lands, or for the frame the box
// changes in and the next (the judge reads what the frame drew after it painted). A box that grows later
// on its own (an image's picture decoding to another size) is outside it and still counts.
import { declareMove } from "../../../layout/motionContract";

/** The longest an at-once growth stays declared when its page draws no frames (a hidden page). */
const AT_ONCE_CAP_MS = 120;

/**
 * Declares the composer's growth for `ms` (a running motion), or for this frame and the next. Returns its
 * end: its owner calls it when the next growth replaces it or the composer goes, so none outlives it.
 */
export function declareComposerGrowth(win: Window | null | undefined, by: string, ms?: number): () => void {
  const end = declareMove({ event: "composer-growth", scope: "all", by }, { ms: ms ?? AT_ONCE_CAP_MS });
  if (ms === undefined && win?.requestAnimationFrame) win.requestAnimationFrame(() => win.requestAnimationFrame(end));
  return end;
}
