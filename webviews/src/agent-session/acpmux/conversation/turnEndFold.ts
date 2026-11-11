// A turn's end folds its work once, in place (Leo, 2026-11-08: "while you're working on stuff, you
// expose it. You show it ... and you only do the overarching fold at the very end"), and fast (Leo,
// 2026-11-11: "It should just be there, because it already was there. Now all you're doing is just
// moving [stuff] around. So, like, it should not be slow. It should not look like a PowerPoint
// transition slide fade-in.").
//
// While a turn runs its calls stay in sight (turns.ts `codexRuns`). When it ends, one update swaps
// each run of those rows for its closed "Worked for" line where it ran (turns.ts `workStretches`):
// nothing is reordered and the answer is already on screen. This file plays that swap as a FLIP in
// the view's own coordinates:
// - before the swap renders, the rows drawn now are read: each one's top in the view, and a drawn
//   copy of each row the swap takes away (`captureTurnEnd`, from VirtualTranscript's render);
// - after the swap is placed (the transcript's placement pass, which pins the bottom when the view
//   follows the latest row), each row that stays slides from where it was drawn to its place on one
//   short clock (`TURN_END_FOLD_MS`, the micro step, 120 ms: 15 frames at 120 Hz) on the house
//   ease-out; the rows the swap took away go at once (`collapse`, shipped) or are clipped shut on the
//   same clock (`clip`), never faded; a row the swap added (the folded line) is drawn at full ink
//   where it lands, never faded in. A move longer than the view snaps (`snap` always does): its rows
//   come from out of sight, and nothing the reader reads would travel with it.
// Only `translate` and `clip-path` play, which never change layout and run on the compositor, so the
// fold holds 120 Hz and nothing the virtualizer measures moves; at the bottom the answer stays where it
// is drawn while the rows above it come down to meet the folded line. Reduce Motion,
// `data-agent-motion="off"` or no Web Animations: the swap applies at once and nothing here runs. The
// work is bounded by the rows mounted now (the view's window), never the whole chat.
import { MOTION_EASE_OUT, MOTION_MS } from "../../../motion/scale.generated";
import { bezierAt, parseBezier, type CubicBezier } from "../../../ui/cubicBezier";
import { currentChatMetrics } from "../chatDisplay";
import { foldMs } from "./fold";
import { ARRIVAL_FRAME_LINES } from "./followChase";
import { clippedBottom, ghostOf } from "./turnFold";
import { LIVE_THINKING } from "./turns";
import { isLineRow, type AcpmuxRow } from "../model";

/// How the fold plays. `collapse` (shipped): the rows that go leave at once and the rows that stay
/// close the gap on the fold's short clock. `clip`: the rows that go stay drawn and are clipped shut
/// from their bottom on the same clock, as a disclosure closing. `snap`: the swap at once, no motion.
/// Before (#41034 and earlier): `fade`, `tuck` and `stagger` faded the rows that went over 180 ms and
/// longer, up to 1.2 s for a long fold, and faded the folded line in.
export type TurnEndLook = "collapse" | "clip" | "snap";
export const TURN_END_LOOKS: readonly TurnEndLook[] = ["collapse", "clip", "snap"];
/// The look's attribute, on the transcript or any element over it (the gallery's variants set it).
export const TURN_END_LOOK_ATTR = "data-turn-end-fold";
/// Set on the thread while the fold plays (tests and the gallery's shift gate read it).
export const TURN_END_ATTR = "data-turn-end-folding";

/// The fold's one clock (ms): the micro step, 15 frames at 120 Hz. Leo, 2026-11-11, on the fold that
/// ran 180 ms and grew to 720 ms and past for a long move: "it should not be slow".
export const TURN_END_FOLD_MS = MOTION_MS.micro;
/// The fold's curve: the house ease-out, which never overshoots.
export const TURN_END_FOLD_EASE = MOTION_EASE_OUT;
/// How many trailing rows hold the running turn's line: it is the turn's last row, after which come
/// only rows the view adds (a date, the queue's line).
const LINE_TAIL = 6;

/// The running turn's line, the last row of a turn that runs.
const LIVE_LINE = LIVE_THINKING;

/// Whether `rows` holds a running turn's line near its end.
export function hasLiveLine(rows: readonly AcpmuxRow[]): boolean {
  for (let index = rows.length - 1; index >= 0 && index >= rows.length - LINE_TAIL; index -= 1)
    if (rows[index]!.id === LIVE_LINE) return true;
  return false;
}

/// Whether the update from `before` to `after` ends the running turn: its line goes, and the
/// turn's prompt stays. A transcript cut and drawn again (Edit forks before a prompt, a refetch
/// replays the chat under new ids) takes the line away with the prompt: no turn ended there, and
/// nothing folds (a fold there left copies of the rows that went, the edited prompt's among them,
/// over the new transcript).
export function endsTurn(before: readonly AcpmuxRow[] | undefined, after: readonly AcpmuxRow[]): boolean {
  if (before === undefined || before === after || !hasLiveLine(before) || hasLiveLine(after)) return false;
  let prompt: string | undefined;
  for (let index = before.length - 1; index >= 0 && prompt === undefined; index -= 1)
    // The prompt, not a line another agent's message or the inbox drew (model.ts `isLineRow`): such a
    // line regroups under a new id as the turn ends, and its id going is no cut transcript.
    if (before[index]!.kind === "user" && !isLineRow(before[index]!)) prompt = before[index]!.id;
  return prompt === undefined || after.some((row) => row.id === prompt);
}

/// A row drawn at the swap: where its top was in the view, and its copy when the swap takes it away.
/// `clip`: how much of its bottom a clip hid then (tailGlide.ts clips the row above a row gliding down
/// under it at that row's drawn top), with `shown`, the bottom of what it drew.
type Drawn = { id: string; top: number; copy?: HTMLElement; gone?: true; clip?: number; shown?: number };

/// A clip that hides `bottom` px of a row's bottom and nothing past its other edges (tailGlide.ts's).
const clipBottom = (bottom: number) => `inset(-4096px -4096px ${bottom}px -4096px)`;
/// A clip that hides `top` px of a row's top and `bottom` px of its bottom.
const clipInset = (top: number, bottom: number) => `inset(${top}px -4096px ${bottom}px -4096px)`;
/// How many steps of the fold's progress a `clip` copy's clip is read at.
const CLIP_STEPS = 8;

/// The rows drawn when the turn ended, read before the swap renders.
export type TurnEndCapture = {
  rows: Drawn[];
  /// The view's offset then.
  scrollTop: number;
  sessionId?: string;
};

/// What a fold plays, so a later one (or the transcript unmounting) can settle it first.
export type TurnEndFold = {
  animations: Set<Animation>;
  copies: Set<HTMLElement>;
  timer?: ReturnType<typeof setTimeout>;
  /// Stops the passes that follow the rows as they are placed again (the observer and listener).
  stop?: () => void;
};

const mounted = (thread: HTMLElement) => thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]");

/// Reads the rows `thread` draws now, before `after` replaces them: undefined when the fold would
/// not show (no motion, or the running turn's line is not drawn, the turn's end out of view).
export function captureTurnEnd(
  thread: HTMLElement | null,
  scroller: HTMLElement | null,
  after: readonly AcpmuxRow[],
  sessionId: string | undefined,
): TurnEndCapture | undefined {
  if (!thread || !scroller || foldMs(thread) <= 0) return undefined;
  const nodes = [...mounted(thread)];
  if (!nodes.some((node) => node.dataset.rowId === LIVE_LINE)) return undefined;
  // The ids the swap keeps, from the first mounted row on: rows before the window never matter.
  const first = Math.max(
    0,
    Math.min(...nodes.map((node) => (Number(node.getAttribute("aria-posinset")) || 1) - 1)) - 1,
  );
  const kept = new Set<string>();
  // The turn's edits card takes its first edit's row id (turns.ts `editsCard`), but it is a new row
  // under the answer, not that run moved: the run goes and the card comes in.
  for (let index = Math.min(first, after.length); index < after.length; index += 1)
    if (!after[index]!.merged) kept.add(after[index]!.id);
  // Only the `clip` look draws the rows that go: the others need no copy of them.
  const copies = turnEndLook(thread) === "clip";
  const rows = nodes.map((node) => {
    const box = node.getBoundingClientRect();
    const id = node.dataset.rowId!;
    // A row clipped over the row gliding under it (tailGlide.ts) draws only down to that row's top:
    // the fold goes on from what it drew, never from its whole box (one read, only while clipped).
    const clip = clippedBottom(node);
    return {
      id,
      top: box.top,
      ...(clip > 0 && { clip, shown: box.bottom - clip }),
      ...(!kept.has(id) && (copies ? { copy: ghostOf(node) } : { gone: true as const })),
    };
  });
  return { rows, scrollTop: scroller.scrollTop, sessionId };
}

/// The look set over `node`, or the shipped one.
export function turnEndLook(node: Element): TurnEndLook {
  const set = node.closest(`[${TURN_END_LOOK_ATTR}]`)?.getAttribute(TURN_END_LOOK_ATTR);
  return TURN_END_LOOKS.includes(set as TurnEndLook) ? (set as TurnEndLook) : "collapse";
}

/// One 120 Hz frame (ms).
const FRAME_MS = 1000 / 120;

/// How many 120 Hz frames the fold takes to settle: its clock, rounded up to whole frames.
export const turnEndFoldFrames = (ms = TURN_END_FOLD_MS) => Math.ceil(ms / FRAME_MS);

/// The straight line.
const LINEAR = "linear";

/// The most a move of `px` on `curve` over the fold's clock moves in any one 120 Hz frame: every
/// frame-long window, read at quarter-frame offsets (a fold's first frame may land anywhere on the grid).
function longestFrame(px: number, curve: CubicBezier, ms = TURN_END_FOLD_MS): number {
  let longest = 0;
  for (let t = 0; t < ms; t += FRAME_MS / 4)
    longest = Math.max(longest, px * (bezierAt(curve, Math.min(1, (t + FRAME_MS) / ms)) - bezierAt(curve, t / ms)));
  return longest;
}

/// The fold's curve for its longest move `px`, on its one short clock (Leo, 2026-11-11: easing is fine
/// "if only it's fast", and it has to hold 120 Hz): the house ease-out when no 120 Hz frame of it moves
/// a row more than ARRIVAL_FRAME_LINES of a line; else the straight line, whose frames are all the
/// same, when that holds; else undefined: the fold snaps. The clock never grows: before, a long fold
/// ran 720 ms and past ("it should not be slow").
export function turnEndFoldEasing(px: number): string | undefined {
  const bound = ARRIVAL_FRAME_LINES * currentChatMetrics().lineHeight + 1e-6;
  const move = Math.abs(px);
  const curve = parseBezier(TURN_END_FOLD_EASE);
  if (move <= bound || (curve && longestFrame(move, curve) <= bound)) return TURN_END_FOLD_EASE;
  if ((move * FRAME_MS) / TURN_END_FOLD_MS <= bound) return LINEAR;
  return undefined;
}

/// Ends `fold` at once, drawn where it lands: its animations finish and its copies go.
export function settleTurnEnd(thread: HTMLElement | null, fold: TurnEndFold | undefined): void {
  if (!fold) return;
  clearTimeout(fold.timer);
  fold.stop?.();
  fold.stop = undefined;
  for (const animation of fold.animations) animation.finish();
  fold.animations.clear();
  for (const copy of fold.copies) copy.remove();
  fold.copies.clear();
  thread?.removeAttribute(TURN_END_ATTR);
}

/// Where `nodes` are laid out in the view, without any translate a fold plays on them: their offset
/// parent's top plus their offsets. All are read before anything is written.
function layoutTops(nodes: readonly HTMLElement[]): number[] {
  const parents = new Map<Element | null, number>();
  return nodes.map((node) => {
    const parent = node.offsetParent;
    let top = parents.get(parent);
    if (top === undefined) {
      top = parent ? parent.getBoundingClientRect().top + parent.clientTop : 0;
      parents.set(parent, top);
    }
    return top + node.offsetTop;
  });
}

/// What one row of the fold plays now: how far from its place it started, and its animations.
type Moving = { delta: number; animations: Animation[]; clip?: number };

/// Plays the fold the swap after `capture` makes, from the pass that placed the new rows. Each row
/// drawn then and drawn now slides from where it was to its place on the fold's clock; a row the swap
/// took away goes at once, or (`clip`) is clipped shut where it was drawn on the same clock; a row the
/// swap added is drawn where it lands at full ink. The rows are placed again while the fold plays (a
/// row measured, the bottom kept pinned): each time, every row's start is read again against its new
/// place, on the fold's one clock, so the motion lands where the rows are. Undefined when nothing moves
/// (another chat, no row drawn then is drawn now, or a move longer than the view, which snaps). The
/// passes stop with the fold: its timer, a later fold, or unmount.
export function playTurnEnd(
  thread: HTMLElement,
  capture: TurnEndCapture,
  sessionId: string | undefined,
  scroller?: HTMLElement | null,
): TurnEndFold | undefined {
  if (capture.sessionId !== sessionId || foldMs(thread) <= 0) return undefined;
  const look = turnEndLook(thread);
  if (look === "snap") return undefined;
  const ms = TURN_END_FOLD_MS;
  /// The curve, picked from the first pass's longest move (`turnEndFoldEasing`); a later pass that
  /// finds a move too long for it snaps the fold.
  let easing: string | undefined;
  const fold: TurnEndFold = { animations: new Set(), copies: new Set() };
  // The fold's clock starts with the first frame that paints it. A pass before that frame runs (the
  // rows measured and placed again in the long frame the swap renders) plays from the start, so the
  // first painted frame is the fold's first, never most of the way there in one step.
  const View = thread.ownerDocument.defaultView;
  const timeline = thread.ownerDocument.timeline;
  const now = () => (typeof timeline?.currentTime === "number" ? timeline.currentTime : performance.now());
  let startedAt: number | undefined;
  const firstFrame = View?.requestAnimationFrame(() => (startedAt = now()));
  const play = (node: HTMLElement, keyframes: Keyframe[], timing: KeyframeAnimationOptions = {}) => {
    // On the fold's clock: a pass after its first frame starts each animation part way, in step.
    const delay = -(startedAt === undefined ? 0 : Math.max(0, now() - startedAt));
    const animation = node.animate(keyframes, { duration: ms, easing: easing ?? TURN_END_FOLD_EASE, ...timing, delay });
    fold.animations.add(animation);
    return animation;
  };
  // The rows the swap kept, by id; a row it took away left its copy, and its id may come back as a new
  // row (the edits card), which is drawn as one.
  const was = new Map(capture.rows.filter((row) => !row.copy && !row.gone).map((row) => [row.id, row]));
  // Collapsed, the rows that went are gone at once: no copy is drawn.
  const gone = look === "clip" ? capture.rows.filter((row) => row.copy) : [];
  const moving = new Map<HTMLElement, Moving>();
  const viewHeight = scroller?.clientHeight ?? View?.innerHeight ?? Infinity;
  let snapped = false;
  const pass = () => {
    if (snapped) return;
    const nodes = [...mounted(thread)];
    if (gone.length > 0 && fold.copies.size === 0) {
      // Each copy goes in before the rows that stay, so they draw over it.
      const below = nodes[0] ?? null;
      for (const row of gone) {
        thread.insertBefore(row.copy!, below);
        fold.copies.add(row.copy!);
      }
    }
    // Every place is read before anything plays, so a pass lays the page out once.
    const tops = layoutTops(nodes);
    const deltas = nodes.map((node, index) => {
      const before = was.get(node.dataset.rowId!);
      return before ? before.top - tops[index]! : 0;
    });
    // A move longer than the view snaps: the rows come from out of sight. So does one the short clock
    // cannot play at 120 Hz on its curve (`turnEndFoldEasing`).
    const longest = Math.max(0, ...deltas.map(Math.abs));
    const fits = turnEndFoldEasing(longest);
    if (longest > viewHeight || fits === undefined || (easing === TURN_END_FOLD_EASE && fits === LINEAR)) {
      snapped = true;
      settleTurnEnd(thread, fold);
      return;
    }
    easing ??= fits;
    // The rows that start clipped this pass: where each starts and its bottom at rest.
    nodes.forEach((node, index) => {
      const before = was.get(node.dataset.rowId!);
      if (!before) return;
      const delta = deltas[index]!;
      // A row the tail glide clipped over the row gliding under it when the turn ended (a reply's
      // newest lines over the live line under lag) starts clipped where it drew then and opens on the
      // fold's clock, so its text never draws over a row going away (agent-pane-stream-row-overlap).
      const clip = before.shown === undefined ? 0 : Math.max(0, before.top + node.offsetHeight - before.shown);
      const last = moving.get(node);
      if (last && Math.abs(last.delta - delta) < 0.5 && Math.abs((last.clip ?? 0) - clip) < 0.5) return;
      if (!last && Math.abs(delta) < 0.5 && clip < 0.5) return;
      for (const animation of last?.animations ?? []) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      moving.set(node, {
        delta,
        clip,
        animations: [
          play(node, [{ translate: `0 ${delta}px` }, { translate: "0 0" }]),
          ...(clip >= 0.5
            ? [play(node, [{ clipPath: clipBottom(Math.ceil(clip)) }, { clipPath: clipBottom(0) }])]
            : []),
        ],
      });
    });
    // `clip`: each row that went stays where it was drawn and is covered as the rows around it close
    // over it: its top is clipped down to the bottom of the row coming down over it, its bottom up to
    // the top of the row coming up over it, on the same clock and curve, so no frame draws a row that
    // goes under one that stays. Sampled at CLIP_STEPS offsets of the fold's progress.
    for (const row of gone) {
      const copy = row.copy!;
      if (moving.has(copy)) continue;
      const height = copy.offsetHeight;
      const at = row.top - layoutTops([copy])[0]!;
      let down = 0;
      let downFrom = -Infinity;
      let up = 0;
      let upFrom = Infinity;
      nodes.forEach((node, index) => {
        const before = was.get(node.dataset.rowId!);
        if (!before) return;
        const delta = deltas[index]!;
        // The nearest row that stays above it (the greatest bottom), and the nearest below it.
        if (before.top < row.top && before.top + node.offsetHeight > downFrom) {
          downFrom = before.top + node.offsetHeight;
          down = Math.max(0, -delta);
        } else if (before.top >= row.top && before.top < upFrom) {
          upFrom = before.top;
          up = Math.max(0, delta);
        }
      });
      const frames: Keyframe[] = [];
      for (let step = 0; step <= CLIP_STEPS; step += 1) {
        const progress = step / CLIP_STEPS;
        const top = Math.min(height, Math.max(0, downFrom + down * progress - row.top));
        const bottom = Math.min(height - top, Math.max(0, row.top + height - (upFrom - up * progress)));
        frames.push({ offset: progress, translate: `0 ${at}px`, clipPath: clipInset(top, bottom) });
      }
      moving.set(copy, { delta: at, animations: [play(copy, frames, { fill: "both" })] });
    }
  };
  pass();
  if (snapped || fold.animations.size === 0) {
    settleTurnEnd(thread, fold);
    if (firstFrame !== undefined) View?.cancelAnimationFrame(firstFrame);
    return undefined;
  }
  thread.setAttribute(TURN_END_ATTR, look);
  // Each time the rows are placed again (a row mounts or leaves, a row's offset changes) or the view's
  // offset moves (the bottom kept pinned), the next pass reads them again.
  const observer = View?.MutationObserver
    ? new View.MutationObserver((records) => {
        const placed = (record: MutationRecord) =>
          record.type === "childList"
            ? record.target === thread
            : record.target.parentNode === thread && (record.target as Element).hasAttribute("data-row-id");
        if (records.some(placed)) pass();
      })
    : undefined;
  observer?.observe(thread, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["style", "aria-posinset"],
  });
  scroller?.addEventListener("scroll", pass, { passive: true });
  fold.stop = () => {
    if (firstFrame !== undefined) View?.cancelAnimationFrame(firstFrame);
    observer?.disconnect();
    scroller?.removeEventListener("scroll", pass);
  };
  // A hidden page suspends its animations: nothing of the fold outlasts its length.
  fold.timer = setTimeout(() => settleTurnEnd(thread, fold), ms + 50);
  return fold;
}
