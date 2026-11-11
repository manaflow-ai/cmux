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
// 228 ms after its event (row-arrival-settle.test.ts). A move that comes while one plays goes on from
// where each row is drawn: every row from the anchor down that moves or still glides starts again
// from its drawn place on the pass's one clock, so the whole tail moves as one.
// A row that arrived is not moved: it fades in at its place (`cv-enter-fade`) as the rows under it
// open its room.
//
// No row is ever drawn over the next (Leo, 2026-11-11: "esp when it's lagging, there's a breif moment
// where ther'es overlapping text between the sent out text (from you) and the subequent tool
// calls/thinking"). What pushed the rows down (a reply's new line, a tool call that arrived) is laid
// out at its new size at once, while the rows under it start where they were drawn: for the glide's
// frames they lay over its new part (the live line over the reply's newest line, 22 px; a thought
// row over the reply's end, 40 px; overlap.test agent-pane-stream-row-overlap). So the row above a
// row that glides down is clipped at that row's drawn top on the same clock (`clip-path` inset from
// the bottom, the same easing and length): its new part shows as the room under it opens, one motion,
// the way a row grows. The clip only hides what the row below covers; once the glide lands it goes.
//
// Only `translate` and `clip-path` play, which never change layout: the virtualizer's measured
// heights and the scroll offset stay exact. Stop condition: each glide is one finite animation (the
// step's length), with at most one clip on the row above it, and ends on its own; `stop` cancels what plays and forgets the tops (a chat switch, Jump to latest,
// a resize, a fold or the turn's end moving the rows itself, unmount). The reader's input `hold`s what
// plays where it is drawn, as it holds the follow chase, so nothing moves but their own scroll;
// followed again, `resume` plays it on. Reduce Motion, motion off or
// no Web Animations: the rows move at once, as before. O(mounted rows) per followed pass, the view's
// window (never the whole chat): one offsetTop each, after the pass's own layout, and, only on a pass
// that moves rows while glides still play, two style reads in all (where they are drawn, with and
// without the glides).
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

/// How far `row` is drawn below its place by `translate` (negative: above), from its computed style.
function drawnY(row: HTMLElement): number {
  const value = row.ownerDocument.defaultView?.getComputedStyle(row).translate ?? "";
  if (!value || value === "none") return 0;
  const y = Number.parseFloat(value.split(" ")[1] ?? "");
  return Number.isFinite(y) ? y : 0;
}

/// A clip that hides `bottom` px of a row's bottom and nothing past its other edges (its hover row,
/// focus ring and shadows draw outside its box).
const clipBottom = (bottom: number) => `inset(-4096px -4096px ${bottom}px -4096px)`;

export function createTailGlide(): TailGlide {
  let last: Map<string, { row: HTMLElement; top: number }> | undefined;
  const playing = new Set<Animation>();
  /// The glide and the clip playing on each row.
  const onRow = new Map<HTMLElement, Animation[]>();
  /// Each glide's row (a clip is no glide: it ends with the glides it guards, never on its own).
  const glides = new WeakMap<Animation, HTMLElement>();
  /// The clips each glide guards against, by the glide itself (never by its row): a glide that ends
  /// early (the reader scrolled it out of view, a new pass) takes them with it, or the row above stays
  /// clipped over text nothing covers any more (a reply's last lines hidden after the reader scrolls
  /// back). By glide, not by row: a pass that moves rows while glides play cancels each row's glide
  /// and starts a new one with a new clip, and the old glide's `cancel` event comes later (the Web
  /// Animations API queues it to the next frame's update). Keyed by row, that late event found the
  /// row's new clip in the set and cancelled it, so the row above showed unclipped over the row
  /// gliding under it for the whole new glide (agent-pane-stream-row-overlap: the reply over the
  /// live line, 149 px, a thought over "Running ls -la", 24 px; every frame the clip was gone).
  const guards = new Map<Animation, Set<Animation>>();
  /// Each clip's row, timing, and how far it hides for each row under it: by that row's glide, or
  /// with none for a row that does not glide (the row above glides down onto it, and its own glide's
  /// end takes the clip with everything on its row).
  const clips = new Map<
    Animation,
    { row: HTMLElement; timed: KeyframeAnimationOptions; over: { glide?: Animation; by: number }[] }
  >();
  const live = (animation: Animation) => animation.playState !== "idle" && animation.playState !== "finished";
  const keep = (row: HTMLElement, animation: Animation) => {
    playing.add(animation);
    const list = onRow.get(row);
    if (list) list.push(animation);
    else onRow.set(row, [animation]);
    const done = () => {
      playing.delete(animation);
      const left = onRow.get(row)?.filter((other) => other !== animation);
      if (left?.length) onRow.set(row, left);
      else onRow.delete(row);
    };
    animation.addEventListener("finish", done, { once: true });
    animation.addEventListener("cancel", done, { once: true });
  };
  /// Ends a glide's clips with it, now (its `cancel` event comes a frame later, and a clip left on
  /// for that frame hides the row above over nothing).
  /// A clip that guards other glides still playing stays for them: one row's glide ending early (the
  /// farther row dropped out of view, the nearer still held in it) leaves the row above clipped over
  /// the rows still gliding under it, never drawn over them (review of cmux#41034). When the
  /// glide that ended set the clip's depth, the clip goes on from the same point of the same clock at
  /// the depth the rest need: with all on one curve, that depth at the first frame covers every frame
  /// after it.
  const release = (glide: Animation) => {
    const guarded = guards.get(glide);
    guards.delete(glide);
    for (const clip of guarded ?? []) {
      const of = clips.get(clip);
      // Already ended (its row's own stack cancelled first; the event comes a frame later).
      if (!live(clip)) continue;
      const rest = of?.over.filter((each) => each.glide !== glide && (!each.glide || live(each.glide))) ?? [];
      if (!of || rest.length === 0) {
        clip.cancel();
        continue;
      }
      const depth = (over: { by: number }[]) => Math.ceil(Math.max(...over.map((each) => each.by)));
      if (depth(rest) === depth(of.over)) {
        of.over = rest;
        continue;
      }
      const next = clipOn(of.row, rest, of.timed);
      next.currentTime = clip.currentTime;
      if (clip.playState === "paused") next.pause();
      clip.cancel();
    }
  };
  /// Cancels what plays on `row`, the clips its glide guards with it.
  const cancelOn = (row: HTMLElement) => {
    for (const animation of onRow.get(row) ?? []) {
      animation.cancel();
      release(animation);
    }
  };
  const glideOn = (row: HTMLElement, animation: Animation) => {
    keep(row, animation);
    glides.set(animation, row);
    // A glide ended by anything else (the page, the engine) still takes its own clips, and only them.
    animation.addEventListener("cancel", () => release(animation), { once: true });
    animation.addEventListener("finish", () => guards.delete(animation), { once: true });
  };
  /// Clips `row`'s bottom by the most any row under it needs, opening on `timed`.
  const clipOn = (row: HTMLElement, over: { glide?: Animation; by: number }[], timed: KeyframeAnimationOptions) => {
    const by = Math.ceil(Math.max(...over.map((each) => each.by)));
    const animation = row.animate([{ clipPath: clipBottom(by) }, { clipPath: clipBottom(0) }], timed);
    keep(row, animation);
    clips.set(animation, { row, timed, over });
    for (const { glide } of over) {
      if (!glide) continue;
      const set = guards.get(glide);
      if (set) set.add(animation);
      else guards.set(glide, new Set([animation]));
    }
    const done = () => {
      for (const { glide } of clips.get(animation)?.over ?? over) if (glide) guards.get(glide)?.delete(animation);
      clips.delete(animation);
    };
    animation.addEventListener("finish", done, { once: true });
    animation.addEventListener("cancel", done, { once: true });
    return animation;
  };
  const stop = () => {
    for (const animation of playing) animation.cancel();
    playing.clear();
    onRow.clear();
    guards.clear();
    clips.clear();
    last = undefined;
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
      // By glide: a row out of view ends all it plays, and each clip it guarded ends with it.
      for (const animation of playing) {
        const row = glides.get(animation);
        if (!row || animation.playState !== "paused") continue;
        const box = row.getBoundingClientRect();
        if (box.bottom <= view.top || box.top >= view.bottom) cancelOn(row);
      }
    },
    place(thread, glide, anchor, track = true) {
      // A row the virtualizer unmounted mid-glide: its glide ends with it, and the clips it guarded
      // on the row above with it, so that row never stays clipped over nothing until the glide's
      // time runs out (its last lines hidden). O(playing).
      for (const animation of playing) {
        const row = glides.get(animation);
        if (row && !row.isConnected) cancelOn(row);
      }
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
      // The rows from the anchor on (what lies above the view's top never shows), each with how far
      // this pass moved it against the anchor.
      type Part = { row: HTMLElement; top: number; bottom: number; moved: number; start: number };
      const parts: Part[] = [];
      let moves = false;
      let below = false;
      for (const [id, { row, top }] of now) {
        if (id === anchor) below = true;
        if (!below) continue;
        if (typeof row.animate !== "function") return;
        const was = before.get(id);
        const shift = id === anchor || !was ? 0 : top - was.top - (to.top - from.top);
        const moved = Math.abs(shift) < MIN_MOVE_PX ? 0 : shift;
        if (moved !== 0) moves = true;
        parts.push({ row, top, bottom: row.offsetTop + row.offsetHeight, moved, start: -moved });
      }
      if (!moves) return;
      // A row still gliding starts from where it is drawn: the glide's own part of its translate, read
      // with and without it (a CSS entrance on the row plays on under it), in two style reads for all.
      const gliding = parts.filter((part) => onRow.has(part.row));
      if (gliding.length) {
        const drawn = gliding.map((part) => drawnY(part.row));
        for (const part of gliding) cancelOn(part.row);
        gliding.forEach((part, index) => (part.start += drawn[index]! - drawnY(part.row)));
      }
      const { ms, easing } = timing(
        thread,
        look,
        parts.reduce((most, part) => Math.max(most, Math.abs(part.start)), 0),
      );
      if (!(ms > 0)) return;
      const timed = { duration: ms, easing };
      /// This pass's glide on each row: the clips over a row guard the glide it plays now.
      const slides = new Map<HTMLElement, Animation>();
      for (const part of parts)
        if (Math.abs(part.start) >= MIN_MOVE_PX) {
          const slide = part.row.animate([{ translate: `0 ${part.start}px` }, { translate: "0 0" }], timed);
          glideOn(part.row, slide);
          slides.set(part.row, slide);
        }
      // Each row that a row under it starts drawn over is clipped there, on the same clock: its drawn
      // bottom never passes the drawn top of any row under it. Rows by where they lie, not DOM order
      // (an empty row, the turn's footer before it lands, can sit between the reply and the live
      // line), and against every row under it, not only the next. With both on one curve, a clip of
      // (start above - start below - gap) at the first frame covers every frame after it.
      const laid = parts.filter((part) => part.bottom > part.top).sort((a, b) => a.top - b.top);
      for (let index = 0; index < laid.length; index++) {
        const upper = laid[index]!;
        const over: { glide?: Animation; by: number }[] = [];
        for (const lower of laid.slice(index + 1)) {
          const by = upper.start - lower.start - (lower.top - upper.bottom);
          if (by >= MIN_MOVE_PX) over.push({ glide: slides.get(lower.row), by });
        }
        if (over.length) clipOn(upper.row, over, timed);
      }
    },
  };
}
