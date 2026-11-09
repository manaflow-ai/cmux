// A turn's end folds its work once, in one motion (Leo, 2026-11-08: "while you're working on stuff,
// you expose it. You show it ... and you only do the overarching fold at the very end. And so the
// special thing about this is all of a sudden you know what the target line height will be, instead
// of, like, constantly doing the instant disappear, reappear type shuffle business").
//
// While a turn runs its calls stay in sight (turns.ts `codexRuns`). When it ends, one update swaps
// those rows for the closed "Worked for" line and the answer. This file plays that swap on the
// house settle (`--cmux-motion-settle` on `--cmux-ease-settle`: 265 ms, cubic-bezier(0.16, 1, 0.3,
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
import { cssTimeMs, foldMs } from "./fold";
import { ghostOf } from "./turnFold";
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

/// The house settle when the page has no token (a test DOM): 265 ms.
const SETTLE_FALLBACK_MS = 265; // motion-allow: the house settle's own length (schemas/motion-scale `settle`)
const SETTLE_FALLBACK_EASE = "cubic-bezier(0.16, 1, 0.3, 1)";
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
type Drawn = { id: string; top: number; copy?: HTMLElement };

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
    return { id, top: box.top, ...(!kept.has(id) && { copy: ghostOf(node) }) };
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
type Moving = { delta: number; fades: boolean; animations: Animation[] };

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
  const { ms, easing } = settle(thread);
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
    const restart = (
      node: HTMLElement,
      store: Map<HTMLElement, Moving>,
      next: Moving,
      keyframes: () => Keyframe[][],
    ) => {
      const last = store.get(node);
      if (last && Math.abs(last.delta - next.delta) < 0.5 && last.fades === next.fades) return;
      for (const animation of last?.animations ?? []) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      next.animations = keyframes().map((frames) => play(node, frames));
      store.set(node, next);
    };
    nodes.forEach((node, index) => {
      const before = was.get(node.dataset.rowId!);
      if (!before) {
        // A row the swap added fades in where it lands, unless it plays its own entrance.
        if (node.matches(".acpmux-row--enter, .acpmux-row--message-enter")) return;
        restart(node, moving, { delta: 0, fades: true, animations: [] }, () => [[{ opacity: 0 }, { opacity: 1 }]]);
        return;
      }
      const delta = before.top - tops[index]!;
      if (Math.abs(delta) < 0.5 && !moving.has(node)) return;
      restart(node, moving, { delta, fades: false, animations: [] }, () => [
        [{ translate: `0 ${delta}px` }, { translate: "0 0" }],
      ]);
    });
    copies.forEach((copy, order) => {
      const row = gone.find((entry) => entry.copy === copy)!;
      const at = row.top - copyTops[order]!;
      const end = look === "tuck" && line !== undefined ? at + (line - row.top) : at;
      const last = copyMoves.get(copy);
      if (last && Math.abs(last.delta - at) < 0.5) return;
      for (const animation of last?.animations ?? []) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      const timing: KeyframeAnimationOptions = { fill: "forwards" };
      if (look === "stagger") {
        // The last row first, each a step after the one under it, inside the fold's own length.
        const step = Math.min(40, ms / Math.max(2, copies.length * 2)); // motion-allow: a share of the settle
        timing.delay = (copies.length - 1 - order) * step;
        timing.duration = Math.max(ms / 2, ms - timing.delay);
      }
      const motion = play(
        copy,
        [
          { translate: `0 ${at}px`, opacity: 1 },
          { translate: `0 ${end}px`, opacity: 0 },
        ],
        timing,
      );
      copyMoves.set(copy, { delta: at, fades: true, animations: [motion] });
    });
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
