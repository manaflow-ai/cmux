// The rows under a change glide to their new place while the view follows the latest row (Leo,
// 2026-11-07: "the streaming text, and then, like, when you stream text, and then you get this
// burst, and then all of a sudden, then you start thinking. It's like, okay, the jumps are jarring.
// We want to minimize the jumps").
//
// While the view follows a running turn, the follow chase (followChase.ts) keeps the row at the
// view's top (its anchor) moving smoothly: it draws the whole thread back by whatever moved that row
// and brings it home on its spring. What lands below the anchor moves the rows under it at once,
// though, relative to the rows the reader is reading: the running turn's live line ("Thinking",
// "Read relay.ts") jumped 28 px when a call took its row, 56 px when a thought ended and the reply
// began, and 115 px when a steer came in under a running call; the steer itself jumped 32 px when
// the stretch before it took its footer (test/turn-transition-jumps.test.ts). Here each placement
// pass the chase follows reads every mounted row's top in the thread's layout (offsetTop, never a
// drawn box, so neither the chase's translate nor this glide's own count) and, for each row that
// moved against the anchor, plays the move as a FLIP on the row's `translate`, from where it was
// drawn to its place, on the entry step (`--agent-motion-in`, 180 ms, ease-out): the clock the row
// that came fades in on (`cv-enter-fade`), so the room opens and the row appears as one motion. On
// the same page the entry step's worst frame was 3.9-10.5 px a turn, the house settle's 5.6-14.5 px
// (turn-transition-jumps.test.ts, CMUX_TURN_TRANSITION_LOOKS). The glides add
// (`composite: "add"`), so a move that comes while one plays goes on from where the row is drawn.
// A row that arrived is not moved: it fades in at its place (`cv-enter-fade`) as the rows under it
// open its room.
//
// Only `translate` plays, which never changes layout: the virtualizer's measured heights and the
// scroll offset stay exact. Stop condition: each glide is one finite animation (the step's length)
// and ends on its own; `stop` cancels what plays and forgets the tops (a chat switch, Jump to latest,
// a resize, a fold or the turn's end moving the rows itself, unmount). Reduce Motion, motion off or
// no Web Animations: the rows move at once, as before. O(mounted rows) per followed pass, the view's
// window (never the whole chat): one offsetTop each, after the pass's own layout.
import { cssTimeMs, foldMs } from "./fold";
import { LIVE_THINKING } from "./turns";

/// How the rows under a change move. `quick` (shipped): on the entry step (180 ms, ease-out), the
/// clock the arriving row fades in on. `glide`: on the house settle (265 ms). `jump`: at once (before).
export type TailGlideLook = "glide" | "quick" | "jump";
export const TAIL_GLIDE_LOOKS: readonly TailGlideLook[] = ["quick", "glide", "jump"];
/// The look's attribute, on the transcript or any element over it (the gallery's variants set it).
export const TAIL_GLIDE_LOOK_ATTR = "data-tail-glide";

/// The house settle and the entry step when the page has no token (a test DOM).
const SETTLE_FALLBACK_MS = 265; // motion-allow: the house settle's own length (schemas/motion-scale `settle`)
const SETTLE_FALLBACK_EASE = "cubic-bezier(0.16, 1, 0.3, 1)";
const QUICK_FALLBACK_MS = 180; // motion-allow: the entry step's own length (schemas/motion-scale `in`)
const QUICK_FALLBACK_EASE = "ease-out";
/// A move under this is a re-rounding, not a move.
const MIN_MOVE_PX = 0.5;

/// The look set over `node`, or the shipped one.
export function tailGlideLook(node: Element): TailGlideLook {
  const set = node.closest(`[${TAIL_GLIDE_LOOK_ATTR}]`)?.getAttribute(TAIL_GLIDE_LOOK_ATTR);
  return TAIL_GLIDE_LOOKS.includes(set as TailGlideLook) ? (set as TailGlideLook) : "quick";
}

function timing(thread: HTMLElement, look: TailGlideLook): { ms: number; easing: string } {
  const style = thread.ownerDocument.defaultView?.getComputedStyle(thread);
  const token = (name: string) => style?.getPropertyValue(name).trim() ?? "";
  if (look === "glide")
    return {
      ms: cssTimeMs(token("--cmux-motion-settle")) ?? SETTLE_FALLBACK_MS,
      easing: token("--cmux-ease-settle") || SETTLE_FALLBACK_EASE,
    };
  return {
    ms: cssTimeMs(token("--agent-motion-in")) ?? QUICK_FALLBACK_MS,
    easing: token("--agent-ease-out") || QUICK_FALLBACK_EASE,
  };
}

/// Each mounted row's top in the thread's layout, by id, in order. The live line counts from its
/// words: its row's padding changes with the row above it (a step row or a reply), its words do not.
function tops(thread: HTMLElement): Map<string, { row: HTMLElement; top: number }> {
  const out = new Map<string, { row: HTMLElement; top: number }>();
  for (const row of thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]")) {
    const id = row.dataset.rowId!;
    let top = row.offsetTop;
    if (id === LIVE_THINKING) {
      const words = row.querySelector<HTMLElement>(".cv-worked--live");
      if (words && words.offsetParent === row) top += words.offsetTop;
    }
    out.set(id, { row, top });
  }
  return out;
}

export type TailGlide = {
  /// One placement pass is done: note where the rows lie, and when `glide` (a pass the follow chase
  /// takes), play each move against `anchor` (the row the chase measured from) since the last pass.
  place(thread: HTMLElement | null, glide: boolean, anchor: string | undefined): void;
  /// Ends what plays, the rows drawn at their places, and forgets where they were.
  stop(): void;
};

export function createTailGlide(): TailGlide {
  let last: Map<string, { row: HTMLElement; top: number }> | undefined;
  const playing = new Set<Animation>();
  const stop = () => {
    for (const animation of playing) animation.cancel();
    playing.clear();
    last = undefined;
  };
  return {
    stop,
    place(thread, glide, anchor) {
      const before = last;
      const now = thread ? tops(thread) : undefined;
      last = now;
      if (!thread || !now || !before || !glide || anchor === undefined || foldMs(thread) <= 0) return;
      const from = before.get(anchor);
      const to = now.get(anchor);
      if (!from || !to) return;
      const look = tailGlideLook(thread);
      if (look === "jump") return;
      const { ms, easing } = timing(thread, look);
      if (!(ms > 0)) return;
      // Only the rows from the anchor on: what lies above the view's top never shows.
      let below = false;
      for (const [id, { row, top }] of now) {
        if (id === anchor) below = true;
        if (!below || id === anchor) continue;
        const was = before.get(id);
        if (!was || typeof row.animate !== "function") continue;
        const moved = top - was.top - (to.top - from.top);
        if (Math.abs(moved) < MIN_MOVE_PX) continue;
        const animation = row.animate([{ translate: `0 ${-moved}px` }, { translate: "0 0" }], {
          duration: ms,
          easing,
          composite: "add",
        });
        playing.add(animation);
        const done = () => playing.delete(animation);
        animation.addEventListener("finish", done, { once: true });
        animation.addEventListener("cancel", done, { once: true });
      }
    },
  };
}
