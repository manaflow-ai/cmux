// A Session Info Show more / Show less (a list's own, the ended subagents, the finished tasks, the
// panel's Show more line) as one state transition (Leo, 2026-11-07: "we also need more animations for
// the session info collapsing/expanding and the inner bits collapsing/expanding and whatnot"). The
// box that holds the rows moves from the height it is drawn at to the height it ends at, and every
// section under it and the panel's own edge move with it on the same frames, since they follow its
// layout. Opening, the new rows are drawn at once and the box uncovers them. Closing, the rows that go
// stay drawn (`drawn`) until the box has closed over them, then leave on the frame it ends, so the
// last frame is the closed layout: no jump and nothing popping in or out. A section's own fold is
// Base UI's (sessionInfo.css `.ui-disclosure-panel`), on the same duration and curve.
//
// Cost: one height read before the change and one after, per toggle; one Web Animation on the box,
// which ends by itself (265 ms, the motion scale's settle). No observer, no frame loop. Under
// Reduce Motion, the pane's animations off, or a hidden page (ui/motion/motionMode.ts), it is instant.
import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react";
import { MOTION_SETTLE, MOTION_SETTLE_MS } from "../../../motion/scale.generated";
import { motionMode } from "../../../ui/motion/motionMode";

/// Whether a fold moves: full motion, and the host's move duration not 0 (Reduce Motion zeroes only
/// that one, theme.ts `data-agent-move`), as the transcript's fold reads it (conversation/fold.ts).
function foldMoves(doc: Document | undefined = typeof document === "undefined" ? undefined : document): boolean {
  return motionMode(doc) === "full" && doc?.documentElement.dataset.agentMove !== "instant";
}

/// How long a fold moves: the settle's measured length (--cmux-motion-settle, schemas/motion-scale).
export const FOLD_MS = MOTION_SETTLE_MS;
/// The settle (--cmux-ease-settle): a strong ease-out that decelerates into the end height and never
/// passes it (Leo, 2026-11-07: "they dont overshoot but they decelerate at the end. i think that might
/// be the key"). Read from the box's --cmux-ease-settle when it has one, so the token is the one place
/// to change it (and a gallery comparison can swap it), else the generated copy.
const foldEase = (box: HTMLElement) =>
  box.ownerDocument.defaultView?.getComputedStyle(box).getPropertyValue("--cmux-ease-settle").trim() || MOTION_SETTLE;

/// The settle's length on `box` (--cmux-motion-settle, so a gallery comparison can swap it), else FOLD_MS.
function foldDuration(box: HTMLElement): number {
  const value =
    box.ownerDocument.defaultView?.getComputedStyle(box).getPropertyValue("--cmux-motion-settle").trim() ?? "";
  const match = /^(\d+(?:\.\d+)?)(ms|s)$/.exec(value);
  if (!match) return FOLD_MS;
  return Number(match[1]) * (match[2] === "s" ? 1000 : 1);
}

export interface FoldMotion<E extends HTMLElement> {
  /// The box that holds the rows: its height moves.
  ref: RefObject<E | null>;
  /// Draw the open rows: open, or still closing over them.
  drawn: boolean;
  /// Flip the fold to `next` through `apply` (the owner's setter): the box moves from what is drawn now.
  toggle: (next: boolean, apply: (next: boolean) => void) => void;
}

/// The height of `box` down to the top of `child` (the first row that goes on a close), as laid out
/// with its list scrolled to the top (a list scrolls back to its top as it closes), or all of it.
export function heightAbove(box: HTMLElement, child: Element | null | undefined): number {
  if (!child) return box.offsetHeight;
  const list = child.parentElement;
  return child.getBoundingClientRect().top - box.getBoundingClientRect().top + (list?.scrollTop ?? 0);
}

/// The fold of a box whose rows open and close with `open`. `closedHeight` measures the box, with the
/// closing rows still drawn, at the height it ends at (`heightAbove` the first one that goes).
export function useFoldMotion<E extends HTMLElement>(
  open: boolean,
  closedHeight: (box: E) => number,
  /// The box's ref, when its owner keeps one of its own.
  boxRef?: RefObject<E | null>,
): FoldMotion<E> {
  const ownRef = useRef<E>(null);
  const ref = boxRef ?? ownRef;
  const from = useRef<number | undefined>(undefined);
  const run = useRef<Animation | undefined>(undefined);
  const [held, setHeld] = useState(false);
  const measureClosed = useRef(closedHeight);
  measureClosed.current = closedHeight;

  const toggle = (next: boolean, apply: (next: boolean) => void) => {
    const box = ref.current;
    // A box drawn only while open (`drawn && <div ref>`) opens from nothing.
    if ((box || next) && next !== open && foldMoves(box?.ownerDocument)) {
      // Where it is drawn now, a fold still running included.
      from.current = box ? box.offsetHeight : 0;
      setHeld(!next);
    } else {
      setHeld(false);
    }
    apply(next);
  };

  // After the change: from the drawn height to the end height, on the box's own layout.
  useLayoutEffect(() => {
    const box = ref.current;
    const start = from.current;
    from.current = undefined;
    const before = run.current;
    run.current = undefined;
    before?.cancel();
    if (!box) return;
    if (start === undefined) {
      // Opened or closed from outside (a reveal that sets the owner's state, not toggle): no motion,
      // and none left running from before, so a close it interrupted never holds its clip.
      delete box.dataset.folding;
      setHeld(false);
      return;
    }
    const end = open ? box.offsetHeight : measureClosed.current(box);
    if (Math.abs(end - start) < 1) {
      // Nothing to move (a fold turned back where it began): no clip left from the one it replaced.
      delete box.dataset.folding;
      if (!open) setHeld(false);
      return;
    }
    box.dataset.folding = "";
    const fold = box.animate([{ height: `${start}px` }, { height: `${end}px` }], {
      duration: foldDuration(box),
      easing: foldEase(box),
      // Closing holds the end height until the rows that go have left (the effect below).
      fill: open ? "none" : "forwards",
    });
    run.current = fold;
    // Finished, or cancelled from outside (the pane's animations turned off cancel every animation in
    // the page): either way the fold lands on its end state, the closing rows gone and the box unclipped.
    // A fold this hook replaced or stopped itself is no longer `run.current` and settles nothing.
    const settle = () => {
      if (run.current !== fold) return;
      if (open) {
        run.current = undefined;
        delete box.dataset.folding;
      } else {
        setHeld(false);
      }
    };
    fold.onfinish = settle;
    fold.oncancel = settle;
  }, [open, ref]);

  // A close ended and its rows are gone: the box's own height is the end height now, so the held one
  // goes in the same commit, before the frame draws.
  useLayoutEffect(() => {
    if (held || open) return;
    const fold = run.current;
    run.current = undefined;
    fold?.cancel();
    const box = ref.current;
    if (box) delete box.dataset.folding;
  }, [held, open, ref]);

  useEffect(
    () => () => {
      const fold = run.current;
      run.current = undefined;
      fold?.cancel();
    },
    [],
  );

  return { ref, drawn: open || held, toggle };
}
