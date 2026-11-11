// A turn's end folds its work once, in one motion (Leo, 2026-11-08: "while you're working on stuff,
// you expose it. You show it ... and you only do the overarching fold at the very end. And so the
// special thing about this is all of a sudden you know what the target line height will be, instead
// of, like, constantly doing the instant disappear, reappear type shuffle business").
//
// While a turn runs its calls stay in sight (turns.ts `codexRuns`). When it ends, one update swaps
// those rows for the closed "Worked for" line and the answer. This file plays that swap on the
// house settle (`--cmux-motion-settle` on `--cmux-ease-settle`: 180 ms, cubic-bezier(0.16, 1, 0.3,
// 1)) as a FLIP in the view's own coordinates:
// - before the swap renders, the rows drawn now are read: each one's top in the view, and a drawn
//   copy of each row the swap takes away (`captureTurnEnd`, from VirtualTranscript's render);
// - after the swap is placed (the transcript's placement pass, which pins the bottom when the view
//   follows the latest row), each row that stays slides from where it was drawn to its place, each
//   row that went leaves its copy where it was, and the copy goes as the look says (`TurnEndLook`);
//   a row the swap added fades in.
// Only `translate` and `opacity` play, which never change layout, so nothing the virtualizer
// measures moves, and at the bottom the bottom stays where it is while the prompt and everything
// above it come down to meet the folded line. Reduce Motion, `data-agent-motion="off"` or no Web
// Animations: the swap applies at once and nothing here runs. The work is bounded by the rows
// mounted now (the view's window), never the whole chat.
import { MOTION_SETTLE, MOTION_SETTLE_MS } from "../../../motion/scale.generated";
import { bezierAt, cssBezier, parseBezier, type CubicBezier } from "../../../ui/cubicBezier";
import { currentChatMetrics } from "../chatDisplay";
import { cssTimeMs, foldMs } from "./fold";
import { ARRIVAL_FRAME_LINES } from "./followChase";
import { clippedBottom, ghostOf } from "./turnFold";
import { LIVE_THINKING } from "./turns";
import { isLineRow, type AcpmuxRow } from "../model";

/// How the rows the fold takes away go. `fade` (shipped): each copy fades out where it was while the
/// rows that stay slide over it. `tuck`: the copies slide up under the folded line as they fade, as
/// if the line drew them in. `stagger`: the copies fade from the last up, one after another.
export type TurnEndLook = "fade" | "tuck" | "stagger";
export const TURN_END_LOOKS: readonly TurnEndLook[] = ["fade", "tuck", "stagger"];
/// The look's attribute, on the transcript or any element over it (the gallery's variants set it).
export const TURN_END_LOOK_ATTR = "data-turn-end-fold";
/// Set on the thread while the fold plays (tests and the gallery's shift gate read it).
export const TURN_END_ATTR = "data-turn-end-folding";

/// The house settle when the page has no token (a test DOM).
const SETTLE_FALLBACK_MS = MOTION_SETTLE_MS;
const SETTLE_FALLBACK_EASE = MOTION_SETTLE;
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
type Drawn = { id: string; top: number; copy?: HTMLElement; clip?: number; shown?: number };

/// How far into the fold (0 to 1, of its progress) a copy of a row that goes has faded out.
const COPY_GONE_AT = 0.6;

/// A clip that hides `bottom` px of a row's bottom and nothing past its other edges (tailGlide.ts's).
const clipBottom = (bottom: number) => `inset(-4096px -4096px ${bottom}px -4096px)`;

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
      ...(!kept.has(id) && { copy: ghostOf(node) }),
    };
  });
  return { rows, scrollTop: scroller.scrollTop, sessionId };
}

/// The look set over `node`, or the shipped one.
export function turnEndLook(node: Element): TurnEndLook {
  const set = node.closest(`[${TURN_END_LOOK_ATTR}]`)?.getAttribute(TURN_END_LOOK_ATTR);
  return TURN_END_LOOKS.includes(set as TurnEndLook) ? (set as TurnEndLook) : "fade";
}

function settle(thread: HTMLElement): { ms: number; easing: string } {
  const style = thread.ownerDocument.defaultView?.getComputedStyle(thread);
  const ms = cssTimeMs(style?.getPropertyValue("--cmux-motion-settle") ?? "") ?? SETTLE_FALLBACK_MS;
  const easing = style?.getPropertyValue("--cmux-ease-settle").trim() || SETTLE_FALLBACK_EASE;
  return { ms, easing };
}

/// One 120 Hz frame (ms), the frame turn-transition-jumps.test.ts reads each move in.
const FRAME_MS = 1000 / 120;

/// The most a fold moves in one 120 Hz frame (px): ARRIVAL_FRAME_LINES of a line, as the arrival
/// step keeps to (followChase.ts `arrivalStepMs`), under the two thirds of a line no transition's frame
/// may move (turn-transition-jumps.test.ts).
const foldFrameBound = () => ARRIVAL_FRAME_LINES * currentChatMetrics().lineHeight;

/// The most a move of `px` over `ms` on `curve` moves in any one 120 Hz frame: every frame-long
/// window, read at quarter-frame offsets, since a fold's first frame may land anywhere on the grid.
/// A window's ends are four quarter frames apart, so each step reads the curve once. It stops at the
/// first window past `over` (the caller only asks whether the move fits). The straight line is read
/// as it is: each frame moves the frame's share of the move.
function longestFoldFrame(px: number, ms: number, curve: CubicBezier, over = Infinity): number {
  if (curve[0] === curve[1] && curve[2] === curve[3]) return px * Math.min(1, FRAME_MS / ms);
  const quarter = FRAME_MS / 4;
  const ring = [0, 1, 2, 3].map((index) => bezierAt(curve, (index * quarter) / ms));
  let longest = 0;
  for (let index = 0; index * quarter < ms; index += 1) {
    const end = bezierAt(curve, ((index + 4) * quarter) / ms);
    longest = Math.max(longest, px * (end - ring[index % 4]!));
    if (longest > over) return longest;
    ring[index % 4] = end;
  }
  return longest;
}

/// Whether a fold of `px` on `ms` and `easing` keeps every frame under the bound. Curves that are not a
/// cubic-bezier() are not read, and fit.
function foldFits(px: number, ms: number, easing: string): boolean {
  const curve = parseBezier(easing);
  const move = Math.abs(px);
  const most = foldFrameBound() + 1e-9;
  return !curve || ms <= 0 || move <= foldFrameBound() || longestFoldFrame(move, ms, curve, most) <= most;
}

/// The first of `count` candidates that `fits`, or undefined: candidates that fit only follow ones
/// that do not (a longer fold, or a curve leaned further toward the straight line, only slows its
/// fastest frame), so it bisects, reading about log2(count) of them. The first is read first: most
/// folds that need a search fit there.
function firstFit(count: number, fits: (index: number) => boolean): number | undefined {
  if (count <= 0) return undefined;
  if (fits(0)) return 0;
  if (!fits(count - 1)) return undefined;
  let low = 1;
  let high = count - 1;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (fits(middle)) high = middle;
    else low = middle + 1;
  }
  return low;
}

/// The straight line, as a cubic-bezier(): its frames are all the same, the move over its frames.
const LINEAR_BEZIER: CubicBezier = [1 / 3, 1 / 3, 2 / 3, 2 / 3];
/// How finely the curve leans toward the straight line at the cap: 1/32 of the way a step.
const LEAN_STEPS = 32;
/// The timings found, by move (whole pixels, rounded up), settle and bound: a fold's passes ask again
/// for the same moves. Kept to the latest few, so it stays small.
const TIMINGS_KEPT = 64;
const timings = new Map<string, { ms: number; easing: string }>();

/// Forgets the timings found (the bench and tests time a search from cold).
export function clearTurnEndFoldMemo(): void {
  timings.clear();
}

/// The fold's length and curve for a move of `px`: the settle's (`ms` on `easing`), changed only as a
/// long move needs to keep every 120 Hz frame under ARRIVAL_FRAME_LINES of a line. The settle runs
/// 180 ms since #39380 ("the animations end to end need to just resolve faster"); on its curve a 69 px
/// fold then moved 19.9 px in its first frame, past the two thirds of a line no transition's frame may
/// move (turn-transition-jumps.test.ts `tool-group`). In order:
/// - a fold under about 45 px keeps the settle as it is;
/// - up to four times `ms` (720 ms), the settle's curve runs longer (100 px: 372 ms);
/// - at four times `ms` the length stays, and the curve leans from the settle's toward a straight line
///   just as far as the frames need, so its first frame, the settle's fastest, is flatter and the
///   fold still ends on its last frame (274 px: 720 ms on cubic-bezier(0.198, 0.854, 0.38, 0.927),
///   13.5 px a frame; 800 px: 720 ms on cubic-bezier(0.306, 0.437, 0.609, 0.719), 13.2 px a frame).
///   Before, the length stopped there on the settle's curve, and the first frame broke the bound
///   (review of #40350: 274 px moved 19.3 px in it, 800 px 56.5 px). Running the settle's curve
///   longer instead keeps the bound only at 1030 ms for 274 px and 3040 ms for 800 px;
/// - past about 1180 px even the straight line breaks the bound at 720 ms, and runs as long as it
///   needs (2000 px: 1222 ms).
/// Curves that are not a cubic-bezier() keep `ms` and `easing`.
export function turnEndFoldTiming(px: number, ms: number, easing: string): { ms: number; easing: string } {
  const curve = parseBezier(easing);
  const most = foldFrameBound();
  if (!curve || ms <= 0 || Math.abs(px) <= most) return { ms, easing };
  // Read for the whole pixels over the move: what fits them fits the move.
  const move = Math.ceil(Math.abs(px));
  const key = `${move} ${ms} ${easing} ${most}`;
  const known = timings.get(key);
  if (known) {
    timings.delete(key);
    timings.set(key, known);
    return known;
  }
  const found = searchFoldTiming(move, ms, easing, curve, most);
  timings.set(key, found);
  if (timings.size > TIMINGS_KEPT) timings.delete(timings.keys().next().value!);
  return found;
}

/// turnEndFoldTiming's search, for a move past the bound: each step bisects (`firstFit`), and each
/// candidate stops at its first frame past the bound, so a move of any length reads a few hundred
/// points of the curve, never tens of thousands (review of #40627: 9.6 ms for 274 px).
function searchFoldTiming(
  move: number,
  ms: number,
  easing: string,
  curve: CubicBezier,
  most: number,
): { ms: number; easing: string } {
  const over = most + 1e-9;
  const fits = (length: number, on: CubicBezier) => longestFoldFrame(move, length, on, over) <= over;
  const cap = Math.ceil(4 * ms);
  // The settle's curve, a frame longer a step, up to the cap.
  const lengths: number[] = [];
  for (let length = ms; length < cap; length += FRAME_MS) lengths.push(Math.ceil(length));
  const longer = firstFit(lengths.length, (index) => fits(lengths[index]!, curve));
  if (longer !== undefined) return { ms: lengths[longer]!, easing };
  // The curve the browser plays is the CSS text's, so each lean is read back from it.
  const leanText = (step: number) => {
    if (step === 0) return easing;
    const lean = curve.map((value, index) => value + ((LINEAR_BEZIER[index]! - value) * step) / LEAN_STEPS);
    return cssBezier(lean as unknown as CubicBezier);
  };
  const lean = firstFit(LEAN_STEPS + 1, (step) => fits(cap, parseBezier(leanText(step))!));
  if (lean !== undefined) return { ms: cap, easing: leanText(lean) };
  let length = Math.max(cap, Math.ceil((move * FRAME_MS) / most));
  while (!fits(length, LINEAR_BEZIER)) length += 1;
  return { ms: length, easing: cssBezier(LINEAR_BEZIER) };
}
/// How long after its first painted frame a fold's clock may still grow: three 120 Hz frames (two at
/// 60 Hz), the frames in which the virtualizer mounts the rows above the swap. A pass later in the
/// fold (a row unmounted far above, the pinned bottom's scroll) keeps the clock: a retarget then
/// moved the rows 35 px in one frame (turn-transition-jumps `text-tool`, end step, 208 ms in).
const GROW_WINDOW_MS = 3 * FRAME_MS;

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
type Moving = { delta: number; fades: boolean; animations: Animation[]; clip?: number; end?: number };

/// Plays the fold the swap after `capture` makes, from the pass that placed the new rows. Each row
/// drawn then and drawn now slides from where it was to its place, a copy of each row the swap took
/// away goes where it was drawn, and a row the swap added fades in. The rows are placed again while
/// the fold plays (a new row measured, the bottom kept pinned): each time, every row's start is read
/// again against its new place, on the fold's one clock, so the motion lands where the rows are and
/// never where an estimate put them. Undefined when nothing moves (another chat, or no row drawn
/// then is drawn now or went). The passes stop with the fold: its timer, a later fold, or unmount.
export function playTurnEnd(
  thread: HTMLElement,
  capture: TurnEndCapture,
  sessionId: string | undefined,
  scroller?: HTMLElement | null,
): TurnEndFold | undefined {
  if (capture.sessionId !== sessionId || foldMs(thread) <= 0) return undefined;
  const { ms: settleMs, easing: settleEasing } = settle(thread);
  // The fold's one clock: the settle, lengthened (and past four settles, its curve flattened) as a
  // pass finds a longer move (turnEndFoldTiming). Rows
  // the virtualizer mounts above after the swap move the rows under them again, so the first pass's
  // moves are not the longest (turn-transition-jumps `tool-group`: 2 px at the first pass, 77 px at
  // the next). When the clock grows it starts again from that pass, and every row and copy goes on
  // from where it was drawn in the last painted frame (its place and ink then), never from the swap's:
  // nothing is drawn back and no fading copy comes back up.
  let ms = settleMs;
  let easing = settleEasing;
  let grew = false;
  const look = turnEndLook(thread);
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
    const delay = (timing.delay ?? 0) - (startedAt === undefined ? 0 : Math.max(0, now() - startedAt));
    const animation = node.animate(keyframes, { duration: ms, easing, ...timing, delay });
    fold.animations.add(animation);
    return animation;
  };
  // The rows the swap kept, by id; a row it took away left its copy, and its id may come back as
  // a new row (the edits card), which comes in as one.
  const was = new Map(capture.rows.filter((row) => !row.copy).map((row) => [row.id, row]));
  const gone = capture.rows.filter((row) => row.copy);
  const moving = new Map<HTMLElement, Moving>();
  const copyMoves = new Map<HTMLElement, Moving>();
  /// Where each row's or copy's motion on the current clock starts (a top in the view, as `tops`),
  /// and its ink then: the swap's for the first clock, the drawn ones when the clock grows.
  const starts = new Map<HTMLElement, { top?: number; opacity?: number; shown?: number }>();
  /// Each row's and copy's laid-out top at the last pass: with its translate then, where it was drawn.
  const laid = new Map<HTMLElement, number>();
  const pass = () => {
    const nodes = [...mounted(thread)];
    if (gone.length > 0 && fold.copies.size === 0 && copyMoves.size === 0) {
      // The rows that went: each copy goes in before the rows that stay, so they draw over it.
      const below = nodes[0] ?? null;
      for (const row of gone) {
        thread.insertBefore(row.copy!, below);
        fold.copies.add(row.copy!);
      }
    }
    const copies = gone.map((row) => row.copy!).filter((copy) => fold.copies.has(copy));
    // Every place is read before anything plays, so a pass lays the page out once.
    const tops = layoutTops(nodes);
    const copyTops = layoutTops(copies);
    // The folded line: the first row the swap added (the turn's "Worked for"). Copies tuck under it.
    const line = tops.find((_, index) => !was.has(nodes[index]!.dataset.rowId!));
    const startTop = (node: HTMLElement, fallback: number) => starts.get(node)?.top ?? fallback;
    const longestMove = () => {
      let longest = 0;
      nodes.forEach((node, index) => {
        const before = was.get(node.dataset.rowId!);
        if (before) longest = Math.max(longest, Math.abs(startTop(node, before.top) - tops[index]!));
      });
      if (look === "tuck" && line !== undefined)
        copies.forEach((copy) => {
          const row = gone.find((entry) => entry.copy === copy)!;
          longest = Math.max(longest, Math.abs(line - startTop(copy, row.top)));
        });
      return longest;
    };
    // From where each row now starts: a move that needs more time than the clock has grows it, in
    // the fold's first frames only.
    const early = startedAt === undefined || now() - startedAt <= GROW_WINDOW_MS;
    grew = early && !foldFits(longestMove(), ms, easing);
    if (grew) {
      if (startedAt !== undefined) {
        // A frame has painted: each row and copy goes on from where it was drawn. All reads first.
        const drawn = [...moving.keys(), ...copyMoves.keys()].flatMap((node) => {
          const top = laid.get(node);
          if (top === undefined) return [];
          const style = (View ?? window).getComputedStyle(node);
          const y = style.translate === "none" ? 0 : Number.parseFloat(style.translate.split(" ")[1] ?? "") || 0;
          const clip = moving.get(node)?.clip ? clippedBottom(node) : 0;
          const shown = clip > 0 ? top + y + node.offsetHeight - clip : undefined;
          return [{ node, top: top + y, opacity: Number.parseFloat(style.opacity), shown }];
        });
        for (const { node, top, opacity, shown } of drawn)
          starts.set(node, { top, opacity: Number.isFinite(opacity) ? opacity : undefined, shown });
        startedAt = now();
      }
      // A longer move never shortens the clock: on the same curve, more time only slows each frame.
      const timing = turnEndFoldTiming(longestMove(), settleMs, settleEasing);
      ms = Math.max(ms, timing.ms);
      easing = timing.easing;
      if (fold.timer !== undefined) {
        clearTimeout(fold.timer);
        fold.timer = setTimeout(() => settleTurnEnd(thread, fold), ms + 50);
      }
    }
    const restart = (
      node: HTMLElement,
      store: Map<HTMLElement, Moving>,
      next: Moving,
      keyframes: () => Keyframe[][],
    ) => {
      const last = store.get(node);
      if (
        !grew &&
        last &&
        Math.abs(last.delta - next.delta) < 0.5 &&
        last.fades === next.fades &&
        Math.abs((last.clip ?? 0) - (next.clip ?? 0)) < 0.5
      )
        return;
      for (const animation of last?.animations ?? []) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      next.animations = keyframes().map((frames) => play(node, frames));
      store.set(node, next);
    };
    /// The rows that start clipped this pass: where each starts, the bottom it draws, its bottom at rest.
    const covers: { top: number; bottom: number }[] = [];
    /// Where each copy starts drawn (a top in the view, as `tops`).
    const copyStarts = copies.map((copy) => startTop(copy, gone.find((entry) => entry.copy === copy)!.top));
    nodes.forEach((node, index) => {
      const before = was.get(node.dataset.rowId!);
      if (!before) {
        // A row the swap added fades in where it lands, unless it plays its own entrance.
        if (node.matches(".acpmux-row--enter, .acpmux-row--message-enter")) return;
        const from = starts.get(node)?.opacity ?? 0;
        restart(node, moving, { delta: 0, fades: true, animations: [] }, () => [[{ opacity: from }, { opacity: 1 }]]);
        return;
      }
      const delta = startTop(node, before.top) - tops[index]!;
      // A row the tail glide clipped over the row gliding under it, when the turn ended (a reply's
      // newest lines over the live line under lag, 117 px): its clip went with the glide, so its whole
      // box drew at once over the live line's copy, fading where the line was drawn (agent-pane-
      // stream-row-overlap: 103 px of the reply over "Writing"; Leo, 2026-11-11: "esp when it's
      // lagging, there's a breif moment where ther'es overlapping text between the sent out text (from
      // you) and the subequent tool calls/thinking"). It starts clipped where it drew then and opens on
      // the fold's clock, and each copy it covers goes down out from under it on the same clock (below).
      // It never starts drawn past the top of a copy under it either: the swap's own render can grow
      // it (the reply's last lines revealed as the turn ends, 91 px), and the clip read at the swap
      // came from the pass before that growth, so a clip from it alone left the row's newest line over
      // the copy in the fold's first frame (agent-pane-stream-row-overlap, chromium lagging: 14 px).
      const from = startTop(node, before.top);
      const shown = starts.get(node)?.shown ?? before.shown;
      const height = node.offsetHeight;
      let clip = shown === undefined ? 0 : Math.max(0, from + height - shown);
      for (const copyTop of copyStarts) if (copyTop > from) clip = Math.max(clip, from + height - copyTop);
      if (clip >= 0.5) covers.push({ top: from, bottom: tops[index]! + height });
      if (Math.abs(delta) < 0.5 && clip < 0.5 && !moving.has(node)) return;
      restart(node, moving, { delta, fades: false, animations: [], clip }, () => [
        [{ translate: `0 ${delta}px` }, { translate: "0 0" }],
        ...(clip >= 0.5 ? [[{ clipPath: clipBottom(Math.ceil(clip)) }, { clipPath: clipBottom(0) }]] : []),
      ]);
    });
    copies.forEach((copy, order) => {
      const from = copyStarts[order]!;
      const at = from - copyTops[order]!;
      let end = look === "tuck" && line !== undefined ? line - copyTops[order]! : at;
      // Under a clipped row (above): it ends no higher than that row's bottom at rest, so with the clip
      // opening on the same clock, the row's drawn bottom never passes the copy's drawn top. The move
      // is linear in the fold's progress on both, so where it holds at the first and last frame it
      // holds on every frame between.
      for (const cover of covers) if (cover.top < from) end = Math.max(end, cover.bottom - copyTops[order]!);
      const ink = starts.get(copy)?.opacity ?? 1;
      const last = copyMoves.get(copy);
      if (!grew && last && Math.abs(last.delta - at) < 0.5 && Math.abs((last.end ?? at) - end) < 0.5) return;
      for (const animation of last?.animations ?? []) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      // Held at its start through a stagger's delay too, so a copy that has faded never shows full again.
      const timing: KeyframeAnimationOptions = { fill: "both" };
      if (look === "stagger") {
        // The last row first, each a step after the one under it, inside the fold's own length.
        const step = Math.min(40, ms / Math.max(2, copies.length * 2)); // motion-allow: a share of the settle
        timing.delay = (copies.length - 1 - order) * step;
        timing.duration = Math.max(ms / 2, ms - timing.delay);
      }
      // The copy is gone by COPY_GONE_AT of the fold, while it still moves: the rows coming over its
      // place draw over nothing. Faded on the whole clock, a copy still drew its text, faint, under a
      // row arriving over it in the fold's last frames (agent-pane-stream-row-overlap, once a copy's
      // text counted: 5.5 px under the reply at 94%, and the live line's copy 119 px at 87% under lag).
      const motion = play(
        copy,
        [
          { translate: `0 ${at}px`, opacity: ink },
          { offset: COPY_GONE_AT, opacity: 0 },
          { translate: `0 ${end}px`, opacity: 0 },
        ],
        timing,
      );
      copyMoves.set(copy, { delta: at, fades: true, animations: [motion], end });
    });
    nodes.forEach((node, index) => laid.set(node, tops[index]!));
    copies.forEach((copy, order) => laid.set(copy, copyTops[order]!));
  };
  pass();
  if (fold.animations.size === 0) {
    settleTurnEnd(thread, fold);
    return undefined;
  }
  thread.setAttribute(TURN_END_ATTR, look);
  // Each time the rows are placed again (a row mounts or leaves, a row's offset changes) or the
  // view's offset moves (the bottom kept pinned), the next pass reads them again.
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
