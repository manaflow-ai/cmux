// A followed transcript eases each line a streaming reply grows by (Leo, 2026-10-27: "i feel like
// the text streaming feels just a little jumpy... the animation or lack thereof"). The view's offset
// still lands at the latest row in the pass that grew it, before the frame paints, as
// VirtualTranscript's follow always has ("IMMEDIATELY ... at the bottom every single time", Leo
// 2026-10-21); only what the reader sees eases. The thread is drawn back by the rise and slides to
// rest on the compositor (`translate`, a FLIP), so no row is laid out again and no scroll event
// fires. The new line lands in the room the running turn's live line keeps under the reply while it
// waits hidden, above the bottom stack, never under it (the glide #23807 removed held new text below
// the view's foot), and the transcript rises into place over the motion scale's standard step
// instead of a whole line in one frame. Falls, rows that come or go, and resizes move at once.
//
// Cost: O(1) per rise, and a rise happens when the rows' height changes (a new line, not a token).
// One animation at a time: a rise while one plays starts the next from where the thread is drawn.
// Stop condition: each animation is finite (its duration); `stop` cancels it on reader input, Jump
// to latest, a chat switch and unmount, and `fit` when the room it lands in shrinks below what it
// still holds back (VirtualTranscript).
import { MOTION_EASE_OUT, MOTION_MS } from "../../../motion/scale.generated";
import type { AcpmuxRow, ConversationLayout } from "../model";
import { cssTimeMs } from "./fold";
import { THINKING } from "./turns";

/// Where a shell opts out (the gallery's before variant): `data-follow-glide="off"` on an ancestor.
export const FOLLOW_GLIDE_OFF = '[data-follow-glide="off"]';

/// The room under the last row a rise may land new text in: the running turn's live line as its last
/// row (`below`, conversation/turns.ts codexLiveTurn), which keeps the footer's line and turn gap and
/// waits hidden while the reply streams over it (`quietKey`, Thinking.tsx). 0 without one (Debug
/// `liveLineBelow` or `codexToolRuns` off, a line that names a call, a queue's cards last): there the
/// view steps as before. O(1): the last row only.
export function followRoom(rows: readonly AcpmuxRow[], layout: ConversationLayout): number {
  const last = rows.length - 1;
  const row = rows[last];
  if (!row?.below || row.kind !== THINKING || row.quietKey === undefined) return 0;
  return layout.heights[last] ?? 0;
}

export type FollowGlide = {
  /// The followed view's offset rose by `rose` px in this pass (the rows moved up). Draws the thread
  /// back by that, at most `room` (the room under the last row the new text may land in, so it never
  /// lands under the bottom stack), and slides it to rest. Returns how far it was drawn back.
  rise(thread: HTMLElement | null, rose: number, room: number): number;
  /// How far the thread is still drawn back (px), 0 when at rest.
  outstanding(): number;
  /// The room under the last row is now `room`: a glide drawing the thread back further (the live
  /// line came into view to name a call, or left) stops, so nothing stays under the bottom stack.
  fit(room: number): void;
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
    fit(room) {
      if (running && outstanding() > Math.max(0, room) + 0.5) stop();
    },
    rise(thread, rose, room) {
      if (!thread || typeof thread.animate !== "function" || !(rose > 0.5) || !(room > 0.5)) return 0;
      if (thread.closest(FOLLOW_GLIDE_OFF)) return 0;
      const duration = glideMs(thread);
      if (!(duration > 0)) {
        stop();
        return 0;
      }
      // Where the rows are drawn now, plus the rise the offset just took: they start where the
      // reader saw them, short of the room's end.
      const lag = Math.min(room, outstanding() + rose);
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
