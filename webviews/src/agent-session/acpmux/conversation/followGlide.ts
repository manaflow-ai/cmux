// A followed transcript eases each step it takes with a streaming reply (Leo, 2026-10-27: "i feel
// like the text streaming feels just a little jumpy... the animation or lack thereof"). The view's
// offset still lands at the latest row in the pass that grew it, before the frame paints, as
// VirtualTranscript's follow always has ("IMMEDIATELY ... at the bottom every single time", Leo
// 2026-10-21); only what the reader sees glides. The thread is drawn back by the step and slides to
// rest on the compositor (`translate`, a FLIP), so no row is laid out again and no scroll event
// fires. A reply's new line lands in the room the running turn's line keeps under it and the
// transcript rises into place over the motion scale's standard step, instead of a whole line at
// once. When the room under the last row shrinks (Leo, 2026-10-24: "it ended and then it snapped
// back after it realized it didnt need that much space") the rows ease down the same way.
//
// Cost: O(1) per step, and a step happens when the rows' height changes (a new line, not a token).
// One animation at a time: a step while one plays starts the next from where the thread is drawn.
// Stop condition: each animation is finite (its duration), and `stop` cancels it on reader input,
// Jump to latest, a chat switch and unmount (VirtualTranscript).
import { MOTION_EASE_OUT, MOTION_MS } from "../../../motion/scale.generated";
import type { AcpmuxRow, ConversationLayout } from "../model";
import { cssTimeMs } from "./fold";
import { ACTIVITY_LINE, THINKING, WORKING } from "./turns";

/// Where a shell opts out (the gallery's before variant): `data-follow-glide="off"` on an ancestor.
export const FOLLOW_GLIDE_OFF = '[data-follow-glide="off"]';

/// The room under the last row a rise may land new text in: the running turn's line as its last row
/// (`below`, conversation/turns.ts liveTurn), which keeps the footer's line and turn gap and is quiet
/// while the reply streams over it. 0 without one (Debug `liveLineBelow` off, a queue's cards last):
/// there the view steps as before. O(1): the last row only.
export function followRoom(rows: readonly AcpmuxRow[], layout: ConversationLayout): number {
  const last = rows.length - 1;
  const row = rows[last];
  if (!row?.below || (row.kind !== THINKING && row.kind !== WORKING && row.kind !== ACTIVITY_LINE)) return 0;
  return layout.heights[last] ?? 0;
}

export type FollowGlide = {
  /// The followed view's offset moved by `moved` px in this pass (positive: the rows rose). Starts
  /// the thread's glide and returns how far it was drawn back; 0 when nothing glides. A rise draws
  /// back by at most `room` (the room under the last row the new text may land in, so it never lands
  /// under the bottom stack); a fall by at most `fallCap`.
  step(thread: HTMLElement | null, moved: number, room: number, fallCap: number): number;
  /// How far the thread is still drawn back (px), 0 when at rest.
  outstanding(): number;
  /// Cancels the glide in flight, leaving the rows where they lay out.
  stop(): void;
};

/// The step's duration: the host's move token (`--agent-motion-move`, 0 with motion off), else the
/// motion scale's standard step. None under Reduce Motion or with cmux's motion off.
function glideMs(node: HTMLElement): number {
  const view = node.ownerDocument.defaultView;
  if (!view || view.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return 0;
  if (node.ownerDocument.documentElement.dataset.agentMotion === "off") return 0;
  const token = cssTimeMs(view.getComputedStyle(node).getPropertyValue("--agent-motion-move"));
  return token ?? MOTION_MS.standard;
}

export function createFollowGlide(): FollowGlide {
  let running: Animation | undefined;
  let from = 0;
  const outstanding = () => {
    if (!running) return 0;
    // The effect's easing is in its computed progress.
    const progress = running.effect?.getComputedTiming().progress;
    return typeof progress === "number" ? from * (1 - progress) : 0;
  };
  const stop = () => {
    const animation = running;
    running = undefined;
    from = 0;
    animation?.cancel();
  };
  return {
    outstanding,
    stop,
    step(thread, moved, room, fallCap) {
      if (!thread || typeof thread.animate !== "function" || Math.abs(moved) <= 0.5) return 0;
      if (thread.closest(FOLLOW_GLIDE_OFF)) return 0;
      const duration = glideMs(thread);
      if (!(duration > 0)) {
        stop();
        return 0;
      }
      // Where the rows are drawn now, plus the step the offset just took: they start where the
      // reader saw them.
      const wanted = outstanding() + moved;
      const lag = Math.max(-Math.max(0, fallCap), Math.min(Math.max(0, room), wanted));
      if (Math.abs(lag) <= 0.5) {
        stop();
        return 0;
      }
      running?.cancel();
      from = lag;
      const animation = thread.animate([{ translate: `0 ${lag}px` }, { translate: "0 0" }], {
        duration,
        easing: MOTION_EASE_OUT,
      });
      running = animation;
      animation.onfinish = () => {
        if (running !== animation) return;
        running = undefined;
        from = 0;
      };
      return lag;
    },
  };
}
