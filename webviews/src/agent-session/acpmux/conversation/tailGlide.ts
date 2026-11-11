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
// drawn to its place, on the arrival step (followChase.ts `arrivalStepMs`: the quick step, 80 ms,
// longer only as a long move's frames need; ARRIVAL_EASE): the step the follow chase brings the rows
// above home on and the row that came fades in on (`--agent-motion-arrive`), so everything that moves
// starts in the frame the row lands in and rests together (Leo, 2026-11-09: "the tool call shifting
// the chat animation and stuff is just too slow ... thinking, tool calls, etc... cannot lag nor can
// they take long"). On the entry step (120 ms) and the spring chase, a finished call's move rested
// 228 ms after its event (row-arrival-settle.test.ts). The glides add
// (`composite: "add"`), so a move that comes while one plays goes on from where the row is drawn.
// A row that arrived is not moved: it fades in at its place (`cv-enter-fade`) as the rows under it
// open its room.
//
// A row gliding down never draws over the row above it (Leo, 2026-11-11: "esp when it's lagging,
// there's a breif moment where ther'es overlapping text between the sent out text (from you) and the
// subequent tool calls/thinking"). Down means it starts where it was, over the room the row above
// just took (the reply's new line, a call that arrived), so that row's bottom is cut back to the
// gliding row's drawn top and uncovered on the same step and curve: the new words show as the row
// under them moves off them, never under it, on any frame a slow page draws.
//
// Only `translate` plays, which never changes layout: the virtualizer's measured heights and the
// scroll offset stay exact. Stop condition: each glide is one finite animation (the step's length)
// and ends on its own; `stop` cancels what plays and forgets the tops (a chat switch, Jump to latest,
// a resize, a fold or the turn's end moving the rows itself, unmount). The reader's input `hold`s what
// plays where it is drawn, as it holds the follow chase, so nothing moves but their own scroll;
// followed again, `resume` plays it on. Reduce Motion, motion off or
// no Web Animations: the rows move at once, as before. O(mounted rows) per followed pass, the view's
// window (never the whole chat): one offsetTop each, after the pass's own layout.
import { MOTION_MS, MOTION_SETTLE, MOTION_SETTLE_MS } from "../../../motion/scale.generated";
import { cssTimeMs, foldMs } from "./fold";
import { ARRIVAL_EASE, arrivalStepMs } from "./followChase";
import { LIVE_THINKING } from "./turns";

/// How the rows under a change move. `arrive` (shipped): on the arrival step, with the follow chase on
/// the same step. `quick`: on the entry step (120 ms, ease-out), the follow chase on its spring.
/// `glide`: on the house settle (180 ms), the chase on its spring. `jump`: at once.
export type TailGlideLook = "arrive" | "glide" | "quick" | "jump";
export const TAIL_GLIDE_LOOKS: readonly TailGlideLook[] = ["arrive", "quick", "glide", "jump"];
/// The look's attribute, on the transcript or any element over it (the gallery's variants set it).
export const TAIL_GLIDE_LOOK_ATTR = "data-tail-glide";

/// The house settle and the entry step when the page has no token (a test DOM): the scale's own
/// values, so a test DOM moves as the app does (these were 265 and 180 ms after the scale moved on).
const SETTLE_FALLBACK_MS = MOTION_SETTLE_MS;
const SETTLE_FALLBACK_EASE = MOTION_SETTLE;
const QUICK_FALLBACK_MS = MOTION_MS.micro;
const QUICK_FALLBACK_EASE = "ease-out";
/// A move under this is a re-rounding, not a move.
const MIN_MOVE_PX = 0.5;

/// The look set over `node`, or the shipped one.
export function tailGlideLook(node: Element): TailGlideLook {
  const set = node.closest(`[${TAIL_GLIDE_LOOK_ATTR}]`)?.getAttribute(TAIL_GLIDE_LOOK_ATTR);
  return TAIL_GLIDE_LOOKS.includes(set as TailGlideLook) ? (set as TailGlideLook) : "arrive";
}

/// The arrival step when the page has no token (a test DOM): the motion scale's quick step.
const ARRIVE_FALLBACK_MS = MOTION_MS.quick;

function timing(thread: HTMLElement, look: TailGlideLook, moved: number): { ms: number; easing: string } {
  const style = thread.ownerDocument.defaultView?.getComputedStyle(thread);
  const token = (name: string) => style?.getPropertyValue(name).trim() ?? "";
  if (look === "arrive") {
    const floor = cssTimeMs(token("--agent-motion-arrive")) ?? ARRIVE_FALLBACK_MS;
    return { ms: floor > 0 ? arrivalStepMs(moved, 1, floor) : 0, easing: ARRIVAL_EASE };
  }
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
  /// `track`: the view is followed with the chase on, so a later pass may glide. Otherwise the pass
  /// reads nothing and forgets the tops (a token streamed while the reader holds an older turn open
  /// runs no row reads: transcript-fold-anchor.test.tsx).
  place(thread: HTMLElement | null, glide: boolean, anchor: string | undefined, track?: boolean): void;
  /// Ends what plays, the rows drawn at their places, and forgets where they were.
  stop(): void;
  /// The reader took the view: what plays holds where it is drawn (as the follow chase does).
  hold(): void;
  /// Followed again: what the reader's input held plays on.
  resume(): void;
  /// Ends each held glide whose row lies wholly outside `view` (the scroller's box): nobody sees it
  /// land, so it never plays on under a view the reader comes back to. O(held glides).
  dropUnseen(view: DOMRect): void;
  /// Whether a row is drawn away from its place now (a glide playing or held).
  moving(): boolean;
};

export function createTailGlide(): TailGlide {
  let last: Map<string, { row: HTMLElement; top: number }> | undefined;
  const playing = new Set<Animation>();
  // The rows a glide moves, and the clips each glide uncovers on the rows above it: they end together.
  const gliding = new Set<Element>();
  const clips = new Map<Animation, Animation[]>();
  const stop = () => {
    for (const animation of playing) animation.cancel();
    playing.clear();
    gliding.clear();
    clips.clear();
    last = undefined;
  };
  const keep = (animation: Animation, glided?: Element) => {
    playing.add(animation);
    if (glided) gliding.add(glided);
    const done = () => {
      playing.delete(animation);
      clips.delete(animation);
      if (glided && ![...playing].some((other) => (other.effect as KeyframeEffect | null)?.target === glided))
        gliding.delete(glided);
    };
    animation.addEventListener("finish", done, { once: true });
    animation.addEventListener("cancel", done, { once: true });
  };
  return {
    stop,
    moving: () =>
      [...playing].some((animation) => animation.playState !== "finished" && animation.playState !== "idle"),
    hold() {
      for (const animation of playing) animation.pause();
    },
    resume() {
      for (const animation of playing) if (animation.playState === "paused") animation.play();
    },
    dropUnseen(view) {
      for (const animation of playing) {
        if (animation.playState !== "paused") continue;
        const row = (animation.effect as KeyframeEffect | null)?.target;
        if (!(row instanceof Element)) continue;
        const box = row.getBoundingClientRect();
        if (box.bottom > view.top && box.top < view.bottom) continue;
        animation.cancel();
        for (const clip of clips.get(animation) ?? []) clip.cancel();
      }
    },
    place(thread, glide, anchor, track = true) {
      if (!thread || !track || foldMs(thread) <= 0) {
        last = undefined;
        return;
      }
      const before = last;
      const now = tops(thread);
      last = now;
      if (!before || !glide || anchor === undefined) return;
      const from = before.get(anchor);
      const to = now.get(anchor);
      if (!from || !to) return;
      const look = tailGlideLook(thread);
      if (look === "jump") return;
      // Only the rows from the anchor on: what lies above the view's top never shows.
      let below = false;
      // The rows from the anchor down to this one, and where each one's bottom is drawn as this pass's
      // glides start.
      const placed: { row: HTMLElement; bottom: number }[] = [];
      const origin = thread.getBoundingClientRect().top;
      // How far from its layout top a row is drawn: a glide from an earlier pass may still carry it.
      const drawnOffset = (row: HTMLElement) =>
        gliding.has(row) ? row.getBoundingClientRect().top - origin - row.offsetTop : 0;
      for (const [id, { row, top }] of now) {
        if (id === anchor) below = true;
        if (!below) continue;
        const above = placed.length;
        const here = { row, bottom: row.offsetTop + drawnOffset(row) + row.offsetHeight };
        placed.push(here);
        if (id === anchor) continue;
        const was = before.get(id);
        if (!was || typeof row.animate !== "function") continue;
        const moved = top - was.top - (to.top - from.top);
        if (Math.abs(moved) < MIN_MOVE_PX) continue;
        const { ms, easing } = timing(thread, look, moved);
        if (!(ms > 0)) return;
        // Where the row is drawn now (a glide still playing adds to this one), from its layout top.
        const drawn = drawnOffset(row);
        const animation = row.animate([{ translate: `0 ${-moved}px` }, { translate: "0 0" }], {
          duration: ms,
          easing,
          composite: "add",
        });
        keep(animation, row);
        const start = row.offsetTop + drawn - moved;
        here.bottom = start + row.offsetHeight;
        // Starting over the rows above (the reply's new line and a call that arrived under it, in one
        // pass): cut each one's bottom back to this row's top, uncovered as this one glides off it.
        // Only the bottom edge: what a row draws past its other sides stays. The walk stops at the
        // first row this one does not cover, so it costs only the rows it starts over.
        const uncovered: Animation[] = [];
        for (let index = above - 1; index >= 0; index--) {
          const prior = placed[index]!;
          const covered = prior.bottom - start;
          if (covered < MIN_MOVE_PX) break;
          if (typeof prior.row.animate !== "function") continue;
          const clip = prior.row.animate(
            [{ clipPath: `inset(-100vh -100vw ${covered}px)` }, { clipPath: "inset(-100vh -100vw 0px)" }],
            { duration: ms, easing },
          );
          keep(clip);
          uncovered.push(clip);
        }
        if (uncovered.length) clips.set(animation, uncovered);
      }
    },
  };
}
