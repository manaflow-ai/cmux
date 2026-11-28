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
import { declareMove } from "../../../layout/motionContract";
import {
  MOTION_MS,
  MOTION_SETTLE,
  MOTION_SETTLE_MS,
  MOTION_SPRING,
  MOTION_SPRING_STEP,
  MOTION_EASE_OUT,
} from "../../../motion/scale.generated";
import { bezierAt, cssBezier, parseBezier, type CubicBezier } from "../../../ui/cubicBezier";
import { currentChatMetrics } from "../chatDisplay";
import { EXIT_EASING, exitLeadMs } from "./exitLead";
import { cssTimeMs, foldMs } from "./fold";
import { ARRIVAL_FRAME_LINES } from "./followChase";
import { boxOf, clippedBottom, clippedBottomOf, coverClip, ghostOf, type CoverPath, isLiveClockNode } from "./turnFold";
import { LIVE_THINKING, WORKED, NEXT_STEP, WORKING } from "./turns";
import { isLineRow, type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import { experimentArm } from "../../../experiments/experiment";
import { turnEndFoldLook, turnEndRecapLook, turnEndSubagentLook, turnEndCrossLook } from "./turnEndFoldLook.experiment";

/// How the rows the fold takes away go. `fade` (shipped): each copy fades out where it was while the
/// rows that stay slide over it. `tuck`: the copies slide up under the folded line as they fade, as
/// if the line drew them in. `stagger`: the copies fade from the last up, one after another.
///
/// The rest are the variants for Leo's "gash" (2026-11-22: "the big fold we do for claude is not good
/// looking enough. it looks like a gash collapsing"): with `fade` the copies are gone in 40 ms and the
/// rows around them then close a blank band (144 px in the big Claude turn) on the settle's fast start.
/// Each fills or softens that band another way; all play only `translate`, `opacity` and `clip-path`:
/// - `crossfade`: no lead; each copy fades over the whole move, cropped by the rows closing over it,
///   so the band holds fading work until it is closed;
/// - `morph`: a tinted card fades in where the work was as the copies go, and shrinks with the rows
///   closing over it into the folded line;
/// - `cascade`: the copies fold up into the folded line one after another, top first, fading as they go;
/// - `glide`: the settle's move on a soft-start ease-in-out (240 ms), no fast first frame;
/// - `spring`: a critically damped spring (no overshoot, 360 ms), its first frame still;
/// - `wait`: the work stays in sight 320 ms after the answer lands, then folds as `fade` does;
/// - `dissolve`: nothing slides; each row that moves fades out where it was and back in where it lands.
///
/// The motion-path looks (Leo, 2026-11-05: "imagine the surface tension of water and water into one
/// another"): content moves on, never leaves a band. Each changes one thing from `fade`, or from the look
/// it names, so the scenario matrix reads one variable at a time:
/// - `sheet` (copy path): no lead; each copy rides with the row under it, so the work slides up under
///   the folded line as one sheet with the answer, cropped by the rows that close over it, its ink going
///   over the move's second half. No band opens: the answer's top edge is the work's bottom edge.
/// - `capped` (curve and length): a speed limit of half the house frame bound; the move runs at that one
///   speed, then decelerates to rest over its second half, as long as its distance needs (180 to 480 ms):
///   no fast first frame, no long tail, and a long move takes longer instead of stepping farther.
/// - `viscous` (per-row timing): every row that moves starts a frame after the one nearer the fold's
///   seam, so the rows above and below are drawn in like a liquid, the nearest first.
/// - `water` (`sheet` on the house spring): the sheet's path on MOTION_SPRING over its step, the curve
///   that starts still and lands without overshoot (`spring` with the sheet's copies).
/// - `edge` (start places): a kept row that starts out of sight starts just past the view's edge, so no
///   row travels farther than it is seen. In a long turn the rows above come in from hundreds of pixels
///   up, and on the settle's 180 ms they are the frame's biggest step.
/// - `anchored` (the view's offset): `fade`, with the view scrolled so the kept row nearest its center
///   lands where it was drawn: the reader's place holds and the fold's change of height goes to the
///   rows above and below it (at the bottom the view can scroll no lower, and the bottom wins).
///
/// The reveal/replace family (Leo, 2026-11-22: "the folding or whatever so-called you... have identified
/// interesting things. but these have conflating variables ... go explore"): nothing slides at all. The
/// rows that move are drawn at their new places at once, and the old frame (a snapshot of each moved row
/// and a copy of each folded one, held where they were drawn) gives way to the new one in place
/// (`playReplace`), the way the View Transitions API swaps two pictures of the page:
/// - `snapshot`: the old frame and the new cross-dissolve on the settle, the new coming in on an
///   ease-out while the old goes on an ease-in, so the moved content's ink never dips (dissolve's blink);
/// - `wipe`: an edge runs down from the Worked for line over the large step, the new frame above it and
///   the old below: every line swaps once, with no fade and no doubled text;
/// - `sprout`: the same edge, feathered: each row crossfades as the edge passes it, so the folded line
///   seems to grow out of the first folded row down through the work;
/// - `defer`: the old frame stays drawn until the reader scrolls, types or points (or the large step
///   four times over passes), then wipes: nothing changes under an eye that is reading.
export type TurnEndLook =
  | "fade"
  | "tuck"
  | "stagger"
  | "crossfade"
  | "morph"
  | "cascade"
  | "glide"
  | "spring"
  | "wait"
  | "dissolve"
  | "sheet"
  | "capped"
  | "viscous"
  | "water"
  | "edge"
  | "anchored"
  | "snapshot"
  | "wipe"
  | "sprout"
  | "defer";
export const TURN_END_LOOKS: readonly TurnEndLook[] = [
  "fade",
  "tuck",
  "stagger",
  "crossfade",
  "morph",
  "cascade",
  "glide",
  "spring",
  "wait",
  "dissolve",
  "sheet",
  "capped",
  "viscous",
  "water",
  "edge",
  "anchored",
  "snapshot",
  "wipe",
  "sprout",
  "defer",
];
/// The looks that replace in place (`playReplace`) rather than slide.
const REPLACE_LOOKS: ReadonlySet<TurnEndLook> = new Set(["snapshot", "wipe", "sprout", "defer"]);
/// Set on a moved row's snapshot: the id of the row it pictures (the recorder pairs the two).
export const TURN_END_SNAPSHOT_ATTR = "data-fold-snapshot";

/// How the turn's closing recap (the wrap-up's next-step card, wrapUp.ts) comes in under the answer as
/// the turn ends, in the sliding looks. Leo, 2026-11-22: "that's the recap". It arrives with the fold
/// and waits until no row that moves crosses its box (`clearFraction`), then:
/// - `hold`: fades in over the fold's clock;
/// - `rise`: fades in as it rises half a line into its place, on the house ease-out;
/// - `unfurl`: opens down from its top edge (a clip) as it fades in, as if poured into its room;
/// - `bead`: fades in as it grows from 96% of its size from its top, the way a drop joins the surface.
/// - `place` (shipped): drawn at full ink in its place in the frame it comes, no entrance at all.
/// - `open`: full ink from its first frame, its room opening down from its top edge (a clip, no fade),
///   while the rows above rise into the room on the follow's chase at a line a frame, instead of the
///   card's whole height in one frame (VirtualTranscript `recapCame`). Nothing fades up from below.
/// Leo, 2026-11-22: "i think the fade in from the bottom is pretty awkward sometimes when you finish
/// chats. this is in relation to me calling the folding looking like a gash."
export type TurnEndRecap = "hold" | "rise" | "unfurl" | "bead" | "place" | "open";
export const TURN_END_RECAPS: readonly TurnEndRecap[] = ["hold", "rise", "unfurl", "bead", "place", "open"];
export const TURN_END_RECAP_ATTR = "data-turn-end-recap";

/// How a subagent block (it stays out of the fold, turns.ts `staysOut`) gets to its place under the
/// Worked for line in the sliding looks. Leo, 2026-11-22, point 2: "the other one, you can decide as well".
/// - `slide` (shipped): it slides with the rows around it;
/// - `swap`: it does not slide: its snapshot fades where it was as it fades in where it lands;
/// - `dip`: `dissolve` for it alone: out where it was, then in where it lands.
export type TurnEndSubagent = "slide" | "swap" | "dip";
export const TURN_END_SUBAGENTS: readonly TurnEndSubagent[] = ["slide", "swap", "dip"];
export const TURN_END_SUBAGENT_ATTR = "data-turn-end-subagent";
/// How the fold plays when it crosses the person's message (`foldCrossesPerson`; Leo, 2026-11-25: "we
/// simply need to make sure it looks good while doing so. aka fast fades and comfy (maybe eased) and fast
/// and snappy"). One transition, the `fade` look's: the work's copies fade out on the house ease-out over
/// `fadeMs`, then every row that stays moves to its place as one over `moveMs` on `easing`; a row that
/// lands on the other side of the person's message (the answer under a late steer) goes with the copies
/// and is drawn whole where it lands, so nothing slides over the bubble and nothing is drawn twice. Only
/// where the reader sees it (`captureTurnEnd`, rule 1); `snap` (before) draws the swap in one frame.
export type TurnEndCross = "snap" | "quick" | "even" | "eased";
export const TURN_END_CROSSES: readonly TurnEndCross[] = ["snap", "quick", "even", "eased"];
export const TURN_END_CROSS_ATTR = "data-turn-end-cross";
/// Each arm's clocks on the house scale (schemas/motion-scale): the shipped `quick` is the house motion
/// itself, its fade the `micro` step and its move the settle (`--cmux-motion-settle` on
/// `--cmux-ease-settle`, the one fold length every web fold shares), read from the page so one token
/// times every fold and ui.animationSpeed scales this one too; `even` and `eased` are that same clock
/// a beat longer. Reduce Motion and a 0 ms token fold at once (`playTurnEnd` reads `foldMs` first).
const CROSS_TIMING: Record<
  Exclude<TurnEndCross, "snap">,
  (settled: { ms: number; easing: string }, scale: number) => { fadeMs: number; moveMs: number; easing: string }
> = {
  quick: (settled, scale) => ({ fadeMs: MOTION_MS.micro * scale, moveMs: settled.ms, easing: settled.easing }),
  even: (settled, scale) => ({ fadeMs: 140 * scale, moveMs: 200 * scale, easing: settled.easing }),
  eased: (_settled, scale) => ({ fadeMs: 160 * scale, moveMs: 220 * scale, easing: "cubic-bezier(0.4, 0, 0.2, 1)" }),
};

/// The crossing fold set over `node`, else the dev setting's, else the shipped `quick`.
export function turnEndCross(node: Element): TurnEndCross {
  const set = node.closest(`[${TURN_END_CROSS_ATTR}]`)?.getAttribute(TURN_END_CROSS_ATTR);
  if (TURN_END_CROSSES.includes(set as TurnEndCross)) return set as TurnEndCross;
  const arm = experimentArm(turnEndCrossLook);
  return TURN_END_CROSSES.includes(arm) ? arm : "quick";
}

/// The crossing fold's clocks over `node`, on the page's settle token: undefined for `snap`.
export function turnEndCrossTiming(node: HTMLElement): { fadeMs: number; moveMs: number; easing: string } | undefined {
  const cross = turnEndCross(node);
  if (cross === "snap") return undefined;
  const settled = settle(node);
  return CROSS_TIMING[cross](settled, settled.ms / MOTION_SETTLE_MS);
}

/// The subagent block's rows: the group's header and its start and done lines.
const SUBAGENT_CLASSES = ["acpmux-subagents", "acpmux-subagentStarted", "acpmux-subagentDone"];
const isSubagentNode = (node: Element) => SUBAGENT_CLASSES.some((name) => node.classList.contains(name));
/// The look's attribute, on the transcript or any element over it (the gallery's variants set it).
export const TURN_END_LOOK_ATTR = "data-turn-end-fold";
/// `morph`'s card: the tinted surface that stands in for the folded rows while the fold closes.
export const TURN_END_CARD = "acpmux-fold-card";
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
  if (before === undefined || before === after || !hasLiveLine(before)) return false;
  if (hasLiveLine(after)) {
    let worked: string | undefined;
    for (let index = after.length - 1; index >= 0 && index >= after.length - LINE_TAIL; index -= 1) {
      if (after[index]!.kind === "user" && !isLineRow(after[index]!)) break;
      // An ended header: the running one is still the running turn's.
      if (after[index]!.kind === WORKED && after[index]!.turnPhase !== "running") {
        worked = after[index]!.id;
        break;
      }
    }
    if (worked === undefined) return false;
    // The ended header was the running one before (turns.ts `turnHeaderId`: one row, two phases).
    for (let index = before.length - 1; index >= 0 && index >= before.length - LINE_TAIL; index -= 1)
      if (before[index]!.id === worked && before[index]!.turnPhase !== "running") return false;
    if (!before.some((row) => row.id === worked && row.turnPhase === "running")) return false;
  }
  let prompt: string | undefined;
  for (let index = before.length - 1; index >= 0 && prompt === undefined; index -= 1)
    // The prompt, not a line another agent's message or the inbox drew (model.ts `isLineRow`): such a
    // line regroups under a new id as the turn ends, and its id going is no cut transcript.
    if (before[index]!.kind === "user" && !isLineRow(before[index]!)) prompt = before[index]!.id;
  return prompt === undefined || after.some((row) => row.id === prompt);
}

/// Whether `snapshot`'s rows are a copy the page drew before acpmux's attach of the chat answered: a
/// kept tail (a restored tab after Restart to Update, a cache-first open) or the page's saved snapshot.
/// A copy keeps rows, not whether its turn still runs, so a turn its rows show running may have ended
/// long before; the attach that says so is no end the reader is watching (Leo, 2026-11-22, after
/// Restart to Update: "the crazy [very] stupid folding animations somehow replay even though these
/// messages had already been seen by me"). The transcript draws that end in place, as it does a turn
/// that ended while the page was away (VirtualTranscript.tsx `turnEnds`).
export function drawsCopy(snapshot: Pick<AcpmuxSnapshot, "chatAttached" | "drewKeptTail" | "connection">): boolean {
  if (snapshot.chatAttached === true) return false;
  return snapshot.drewKeptTail === true || snapshot.connection.startsWith("connecting");
}

/// A row drawn at the swap: where its top was in the view, and its copy when the swap takes it away.
/// `clip`: how much of its bottom a clip hid then (tailGlide.ts clips the row above a row gliding down
/// under it at that row's drawn top), with `shown`, the bottom of what it drew.
type Drawn = {
  id: string;
  top: number;
  height?: number;
  /// The row is a message the person sent (`isPersonMessage`).
  person?: boolean;
  replacesHeader?: boolean;
  copy?: HTMLElement;
  /// A kept row the swap draws on the other side of a person's message (`landsAcrossPerson`): its copy
  /// goes where it was, and it comes in at its new place once nothing moving crosses it.
  crosses?: boolean;
  /// A kept row's picture as drawn at the swap, for the looks that replace it in place.
  snapshot?: HTMLElement;
  clip?: number;
  shown?: number;
};

/// A clip that hides `bottom` px of a row's bottom and nothing past its other edges (tailGlide.ts's).
const clipBottom = (bottom: number) => `inset(-4096px -4096px ${bottom}px -4096px)`;

/// The rows drawn when the turn ended, read before the swap renders.
export type TurnEndCapture = {
  rows: Drawn[];
  /// The view's offset then.
  scrollTop: number;
  sessionId?: string;
  /// The turn ended where the reader cannot see it: the swap draws at once and no fold plays
  /// (captureTurnEnd, rule 1). Captured all the same, so the turn's end still settles the fold
  /// before it, the follow motion and the tail glide's held clip: with nothing captured at all, a
  /// paused clip stayed on and hid the reply's last lines (review of cmux#41034).
  silent?: boolean;
};

/// What a fold plays, so a later one (or the transcript unmounting) can settle it first.
export type TurnEndFold = {
  animations: Set<Animation>;
  copies: Set<HTMLElement>;
  timer?: ReturnType<typeof setTimeout>;
  /// Stops the passes that follow the rows as they are placed again (the observer and listener).
  stop?: () => void;
  /// Ends the fold's `turn-end` declaration (motionContract.ts), so the judge stops excusing it.
  release?: () => void;
  /// Runs once when the fold is settled (its timer, a later fold, an unmount): the transcript reads
  /// and places its mounted rows again then (VirtualTranscript.tsx `settleMotion`).
  ended?: () => void;
};

const mounted = (thread: HTMLElement) => thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]");

/// A message the person sent, drawn as their bubble: the prompt or a steer, never the line another
/// agent's message or a notice draws (model.ts `isLineRow`).
const isPersonMessage = (node: HTMLElement) =>
  node.classList.contains("acpmux-user") && !node.classList.contains("acpmux-row--line");

/// Whether the fold after `capture` would play across a message the person sent: the swap takes
/// away a row drawn above one of their messages that stays, or takes one of their messages away.
/// Such a swap applies in the frame it renders, with no motion (`playTurnEnd`): the rows over the
/// message and the rows under it would move by different amounts, the bubble between them sliding
/// over the place the folded work drew while its copies faded there (Leo, 2026-11-22: "it tries to
/// fold and it folds up past my [...] steer ... the way i see that [...] passing over my [...]
/// message is so dumb"). A fold plays only under the person's newest message drawn then. Read off
/// the capture alone: no layout, O(rows drawn).
export function foldCrossesPerson(capture: TurnEndCapture): boolean {
  let lowest = -Infinity;
  for (const row of capture.rows) {
    if (!row.person) continue;
    if (row.copy) return true;
    lowest = Math.max(lowest, row.top);
  }
  return capture.rows.some((row) => row.copy !== undefined && row.top < lowest);
}
const heightOf = (node: HTMLElement) => node.offsetHeight;

/// What the fold's passes cost, counted for tests and benches (turn-end-fold-restyle.browser.test.ts):
/// passes run, rows and copies each pass read, the events that asked for a pass (a row placed again,
/// the view's scroll) and the passes that ran in a frame that had already run one.
export const turnEndFoldPerf = {
  passes: 0,
  rowsRead: 0,
  mostRowsRead: 0,
  mutationEvents: 0,
  scrollEvents: 0,
  sameFramePasses: 0,
};
export function resetTurnEndFoldPerf(): void {
  for (const key of Object.keys(turnEndFoldPerf) as (keyof typeof turnEndFoldPerf)[]) turnEndFoldPerf[key] = 0;
}

/// Reads the rows `thread` draws now, before `after` replaces them: undefined when the fold would
/// not show (no motion, or the running turn's line is not drawn, the turn's end out of view).
/// `held`: the swap closes an ended turn's Worked for that was held open while the reader was
/// scrolled up (App.tsx `heldWorked`), which has no live line left to look for.
export function captureTurnEnd(
  thread: HTMLElement | null,
  scroller: HTMLElement | null,
  after: readonly AcpmuxRow[],
  sessionId: string | undefined,
  held = false,
): TurnEndCapture | undefined {
  if (!thread || !scroller || foldMs(thread) <= 0) return undefined;
  const nodes = [...mounted(thread)];
  const liveLine = (node: HTMLElement) => node.dataset.rowId === LIVE_LINE;
  if (!held && !nodes.some(liveLine)) return undefined;
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
  const look = turnEndLook(thread);
  const replaces = REPLACE_LOOKS.has(look);
  const swapsSubagents = turnEndSubagent(thread) !== "slide";
  // The fold plays only where the reader can see it (cmuxterm-hq docs/design/transcript-animation-rules.md,
  // rules 1 and 6): the running line, or a row the swap takes away, in the view. Mounted is not seen: the
  // overscan holds viewports of rows above and below it. Out of sight, the swap draws at once and the
  // anchor keeps the view (Leo, 2026-11-22: "i scroll down, some bullshit ABOVE folds...? and plays an
  // animation!?"). A held Worked for (`held`) has no running line: its work in view is what folds.
  const view = scroller.getBoundingClientRect();
  /// A view of no height has not been laid out yet (a pane measured before its first layout): there
  /// is no view to judge rows against, and reading it as a sliver at the top would swallow a fold the
  /// reader is about to see. Everything counts as seen until the view has a height; nothing is
  /// visible there anyway, so a fold that plays costs only the compositor.
  const unmeasured = view.height === 0;
  // Edges count: an empty slot (a turn of words alone keeps its running line's row at no height) at
  // the view's bottom edge is where the reader is looking.
  const seen = (node: HTMLElement) => {
    if (unmeasured) return true;
    const box = node.getBoundingClientRect();
    return box.bottom >= view.top && box.top <= view.bottom;
  };
  const goes = (node: HTMLElement) => {
    const id = node.dataset.rowId!;
    if (kept.has(id)) return false;
    // The live header stays as the ended one in its slot (below): it does not go.
    return !(node.classList.contains(`acpmux-${WORKING}`) && kept.has(`${WORKED}-${id.slice(WORKING.length + 1)}`));
  };
  if (!nodes.some((node) => seen(node) && ((!held && liveLine(node)) || goes(node))))
    return { rows: [], scrollTop: scroller.scrollTop, sessionId, silent: true };
  const crosses = landsAcrossPerson(nodes, after, kept);
  const rows = nodes.map((node) => {
    const box = node.getBoundingClientRect();
    const priorId = node.dataset.rowId!;
    // The running header is the ended header, one row (turns.ts `turnHeaderId`): it stays, and it is
    // the folded line the copies go under. Running, it holds its chevron's slot unseen (WorkingFor.tsx).
    const id = priorId;
    const header = node.classList.contains(`acpmux-${WORKED}`) && isLiveClockNode(node);
    // A row clipped over the row gliding under it (tailGlide.ts) draws only down to that row's top:
    // the fold goes on from what it drew, never from its whole box (one read, only while clipped).
    const clip = clippedBottom(node);
    return {
      id,
      top: box.top,
      height: box.height,
      ...(isPersonMessage(node) && { person: true }),
      ...(header && kept.has(id) && { replacesHeader: true }),
      ...(clip > 0 && { clip, shown: box.bottom - clip }),
      ...((!kept.has(id) || crosses.has(id)) && { copy: ghostOf(node) }),
      ...(crosses.has(id) && { crosses: true }),
      ...(kept.has(id) &&
        !crosses.has(id) &&
        (replaces || (swapsSubagents && isSubagentNode(node))) && { snapshot: snapshotOf(node, id) }),
    };
  });
  return { rows, scrollTop: scroller.scrollTop, sessionId };
}

/// The kept rows the swap draws on the other side of a message the person sent than they are drawn now
/// (turns.ts `lateSteersLast`: the answer drawn over a late steer lands under it). Such a row goes with
/// the copies and is drawn whole where it lands, never slid across the bubble. O(rows mounted).
function landsAcrossPerson(nodes: readonly HTMLElement[], after: readonly AcpmuxRow[], kept: ReadonlySet<string>) {
  const crosses = new Set<string>();
  const person = new Set(nodes.filter(isPersonMessage).map((node) => node.dataset.rowId!));
  if (person.size === 0) return crosses;
  const placeAfter = new Map(after.map((row, index) => [row.id, index]));
  // Each kept row's count of the person's kept messages above it, before and after the swap.
  const personAt = after.flatMap((row, index) => (person.has(row.id) ? [index] : []));
  let above = 0;
  for (const node of nodes) {
    const id = node.dataset.rowId!;
    if (person.has(id)) {
      if (placeAfter.has(id)) above += 1;
      continue;
    }
    const at = placeAfter.get(id);
    if (at === undefined || !kept.has(id)) continue;
    if (personAt.filter((index) => index < at).length !== above) crosses.add(id);
  }
  return crosses;
}

/// A kept row's picture as drawn now: its copy, marked with the row it pictures.
function snapshotOf(node: HTMLElement, id: string): HTMLElement {
  const copy = ghostOf(node);
  copy.setAttribute(TURN_END_SNAPSHOT_ATTR, id);
  return copy;
}

/// The recap entrance set over `node`, else the dev setting's, else the shipped `place`.
export function turnEndRecap(node: Element): TurnEndRecap {
  const set = node.closest(`[${TURN_END_RECAP_ATTR}]`)?.getAttribute(TURN_END_RECAP_ATTR);
  if (TURN_END_RECAPS.includes(set as TurnEndRecap)) return set as TurnEndRecap;
  const arm = experimentArm(turnEndRecapLook);
  return TURN_END_RECAPS.includes(arm) ? arm : "place";
}

/// The attribute a recap card that arrives live carries: its entrance (conversation.css plays it).
export const RECAP_ENTRANCE_ATTR = "data-recap-entrance";

/// Marks `row` with its recap entrance when it is the recap card, before its entrance's style resolves.
export function markRecapEntrance(row: Element): void {
  if (row.classList.contains(`acpmux-${NEXT_STEP}`)) row.setAttribute(RECAP_ENTRANCE_ATTR, turnEndRecap(row));
}

/// The subagent block's fold set over `node`, else the dev setting's, else the shipped `slide`.
export function turnEndSubagent(node: Element): TurnEndSubagent {
  const set = node.closest(`[${TURN_END_SUBAGENT_ATTR}]`)?.getAttribute(TURN_END_SUBAGENT_ATTR);
  if (TURN_END_SUBAGENTS.includes(set as TurnEndSubagent)) return set as TurnEndSubagent;
  const arm = experimentArm(turnEndSubagentLook);
  return TURN_END_SUBAGENTS.includes(arm) ? arm : "slide";
}

/// The look set over `node`, else the dev setting's (turnEndFoldLook.experiment.ts), else the shipped one.
export function turnEndLook(node: Element): TurnEndLook {
  const set = node.closest(`[${TURN_END_LOOK_ATTR}]`)?.getAttribute(TURN_END_LOOK_ATTR);
  if (TURN_END_LOOKS.includes(set as TurnEndLook)) return set as TurnEndLook;
  const arm = experimentArm(turnEndFoldLook);
  return TURN_END_LOOKS.includes(arm) ? arm : "fade";
}

/// `glide`'s curve: a soft start and a soft landing, so no one frame takes the move's biggest step first.
const GLIDE = { ms: MOTION_MS.large, easing: "cubic-bezier(0.4, 0, 0.2, 1)" };
/// `spring`'s length: a critically damped spring sampled as a CSS linear() curve (it starts still and
/// never overshoots: Leo's "decelerate, no overshoot").
const SPRING_MS = 360;
const SPRING_EASING = (() => {
  const omega = 8.5;
  const points = Array.from({ length: 25 }, (_, index) => {
    const t = index / 24;
    const x = index === 24 ? 1 : 1 - (1 + omega * t) * Math.exp(-omega * t);
    return x.toFixed(4);
  });
  return `linear(${points.join(", ")})`;
})();
/// `wait`'s hold: how long the ended turn's work stays in sight before the fold.
const WAIT_HOLD_MS = 320;

/// `capped`'s curve: constant speed over the first half, then a constant deceleration to rest over the
/// second (continuous speed, zero at the end), sampled as a CSS linear(). The speed is the lowest a curve
/// of that shape can have and land in the step: 4/3 of the straight line's.
const CAPPED_CRUISE = 0.5;
const CAPPED_EASING = (() => {
  const speed = 1 / (1 - CAPPED_CRUISE / 2);
  const points = Array.from({ length: 25 }, (_, index) => {
    const t = index / 24;
    const u = Math.max(0, t - (1 - CAPPED_CRUISE));
    const x =
      index === 24 ? 1 : speed * Math.min(t, 1 - CAPPED_CRUISE) + speed * u - (speed * u * u) / (2 * CAPPED_CRUISE);
    return x.toFixed(4);
  });
  return `linear(${points.join(", ")})`;
})();
/// `capped`'s speed limit: half the house fold's frame bound (foldFrameBound), and the length that keeps a
/// move of `px` under it on CAPPED_EASING, from the settle's length to twice the large step.
function cappedMs(px: number): number {
  const speed = 1 / (1 - CAPPED_CRUISE / 2);
  const ms = (Math.abs(px) * speed * FRAME_MS) / (foldFrameBound() / 2);
  return Math.min(2 * MOTION_MS.large, Math.max(MOTION_SETTLE_MS, ms));
}
/// The motion-path looks whose copies ride with the row under them (`sheet`, `water`).
const ridesSheet = (look: TurnEndLook) => look === "sheet" || look === "water";

/// The look's clock: `glide`, `spring`, `capped` and `water` play their own; the rest the house settle.
function lookTiming(look: TurnEndLook, settled: { ms: number; easing: string }): { ms: number; easing: string } {
  if (look === "glide") return GLIDE;
  if (look === "spring") return { ms: SPRING_MS, easing: SPRING_EASING };
  if (look === "capped") return { ms: settled.ms, easing: CAPPED_EASING };
  if (look === "water") return { ms: MOTION_MS[MOTION_SPRING_STEP], easing: MOTION_SPRING };
  return settled;
}

/// A curve's progress at a time fraction: a cubic-bezier() or a linear() of evenly spaced points.
function curveProgress(easing: string): ((x: number) => number) | undefined {
  const curve = parseBezier(easing);
  if (curve) return (x) => bezierAt(curve, x);
  const linear = /^linear\((.*)\)$/.exec(easing.trim());
  if (!linear) return undefined;
  const points = linear[1]!.split(",").map((point) => Number.parseFloat(point));
  if (points.length < 2 || points.some((point) => !Number.isFinite(point))) return undefined;
  return (x) => {
    const at = Math.min(1, Math.max(0, x)) * (points.length - 1);
    const low = Math.floor(at);
    const high = Math.min(points.length - 1, low + 1);
    return points[low]! + (points[high]! - points[low]!) * (at - low);
  };
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

/// The fold's curve for a move of `px`: the settle's (`ms` on `easing`), its curve changed only as a
/// long move needs, and never its length. The settle runs 180 ms since #39380 ("the animations end to
/// end need to just resolve faster"). #40350 and #40627 ran a long fold longer to keep each 120 Hz
/// frame under ARRIVAL_FRAME_LINES of a line (100 px: 372 ms, 274 px: 720 ms, 2000 px: 1222 ms), and
/// a long reply then crept up its whole move (Leo, 2026-11-11: "It looks like the f***ing Star Wars
/// scroll-up animation ... It should just be there, because it already was there. Now all you're
/// doing is just moving s*** around. So, like, it should not be slow."). In order:
/// - a fold under about 45 px keeps the settle as it is;
/// - a longer one keeps the settle's 180 ms, and its curve leans from the settle's toward a straight
///   line just as far as the frames need, so its first frame, the settle's fastest, is flatter
///   (100 px: cubic-bezier(0.236, 0.708, 0.46, 0.854); 274 px: cubic-bezier(0.328, 0.354, 0.655, 0.677));
/// - past about 295 px even the straight line moves more than the bound in a frame, and the fold still
///   ends with the settle, on the straight line: a long move resolves as fast as a short one.
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

/// turnEndFoldTiming's search, for a move past the bound: it bisects the leans (`firstFit`), and each
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
  const fits = (on: CubicBezier) => longestFoldFrame(move, ms, on, over) <= over;
  // The curve the browser plays is the CSS text's, so each lean is read back from it.
  const leanText = (step: number) => {
    if (step === 0) return easing;
    const lean = curve.map((value, index) => value + ((LINEAR_BEZIER[index]! - value) * step) / LEAN_STEPS);
    return cssBezier(lean as unknown as CubicBezier);
  };
  const lean = firstFit(LEAN_STEPS + 1, (step) => fits(parseBezier(leanText(step))!));
  return { ms, easing: lean !== undefined ? leanText(lean) : cssBezier(LINEAR_BEZIER) };
}
/// How long after its first painted frame a fold's curve may still flatten: three 120 Hz frames (two at
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
  fold.release?.();
  fold.release = undefined;
  thread?.removeAttribute(TURN_END_ATTR);
  const ended = fold.ended;
  fold.ended = undefined;
  ended?.();
}

/// The reader's own scroll ends a fold in flight at once (cmuxterm-hq
/// docs/design/transcript-animation-rules.md, rule 4): its rows drawn where they land, its copies gone.
/// Played on, every pass would turn the scroll into motion (a row the scroll mounts faded in, the
/// scroll's own distance read as a row's move). The fold's `scroll` listener stays for the view's own
/// scrolls (the bottom kept pinned).
const READER_SCROLLS = ["wheel", "touchmove", "pointerdown"] as const;
/// The keys that scroll the view: a reader who reads by keyboard scrolls too (rule 4).
const SCROLL_KEYS = new Set(["PageDown", "PageUp", "Home", "End", "ArrowDown", "ArrowUp", " ", "Spacebar"]);
function endOnReaderScroll(
  thread: HTMLElement,
  scroller: HTMLElement | null | undefined,
  fold: TurnEndFold,
): () => void {
  if (!scroller) return () => {};
  // The input alone is not the reader's scroll. A wheel over a row's own scroller (a code block, a
  // diff, a terminal), or at a bottom that cannot move, bubbles here while the view stays where it
  // was; a press on the scroller is not only its scrollbar, since the space under a chat shorter than
  // the view targets it too. So an input arms, and the view's own `scroll` from it ends the fold:
  // the reader's scroll, never a reader who touched something else.
  let from: number | undefined;
  const arm = () => {
    if (from === undefined) from = scroller.scrollTop;
  };
  const key = (event: Event) => {
    if (SCROLL_KEYS.has((event as KeyboardEvent).key)) arm();
  };
  const moved = () => {
    if (from === undefined || scroller.scrollTop === from) return;
    settleTurnEnd(thread, fold);
  };
  for (const name of READER_SCROLLS) scroller.addEventListener(name, arm, { passive: true });
  scroller.addEventListener("keydown", key, true);
  scroller.addEventListener("scroll", moved, { passive: true });
  return () => {
    for (const name of READER_SCROLLS) scroller.removeEventListener(name, arm);
    scroller.removeEventListener("keydown", key, true);
    scroller.removeEventListener("scroll", moved);
  };
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
/// `covered`: a copy's clip under the rows that come over it (`coverClip`), as its keyframes' text.
type Moving = {
  delta: number;
  fades: boolean;
  animations: Animation[];
  clip?: number;
  /// An arriving row's hold: how long into the move its fade starts (when no kept row crosses it).
  hold?: number;
  end?: number;
  covered?: string;
  crop?: string;
};

/// An ease-in: what goes leaves slowly at first, so with what comes in on the house ease-out the two
/// together never draw less than about nine tenths of a line's ink.
const EASE_IN = "cubic-bezier(0.42, 0, 1, 1)";
/// `rise`'s offset, in lines of the chat's text.
const RISE_LINES = 0.5;
/// `bead`'s starting size.
const BEAD_SCALE = 0.96;

/// The recap card's keyframes for its entrance (`TurnEndRecap`), from ink `from`; `height`, its box's.
function recapEntrance(recap: TurnEndRecap, from: number, height: number): Keyframe[] {
  if (recap === "rise") {
    const rise = RISE_LINES * currentChatMetrics().lineHeight;
    return [
      { opacity: from, translate: `0 ${rise}px` },
      { opacity: 1, translate: "0 0" },
    ];
  }
  if (recap === "unfurl")
    return [
      { opacity: from, clipPath: clipBottom(Math.ceil(height)) },
      { opacity: 1, clipPath: clipBottom(0) },
    ];
  if (recap === "place") return [{ opacity: 1 }, { opacity: 1 }];
  if (recap === "open")
    return [
      { opacity: 1, clipPath: clipBottom(Math.ceil(height)) },
      { opacity: 1, clipPath: clipBottom(0) },
    ];
  if (recap === "bead")
    return [
      { opacity: from, scale: `${BEAD_SCALE}`, transformOrigin: "50% 0" },
      { opacity: 1, scale: "1", transformOrigin: "50% 0" },
    ];
  return [{ opacity: from }, { opacity: 1 }];
}

/// The replace looks' clocks. `snapshot` dissolves on the settle; `wipe` and `defer` run their edge over the
/// large step on `glide`'s soft-start curve; `sprout` runs its edge over the standard step and fades each
/// row over the micro step as the edge passes it.
const WIPE = GLIDE;
const SPROUT_TRAVEL_MS = MOTION_MS.standard;
const SPROUT_FADE_MS = MOTION_MS.micro;
/// `defer`: the longest the old frame stays drawn with no reader's gesture.
const DEFER_MS = MOTION_MS.large * 4;
/// How many points of a wipe's edge each clip's keyframes sample (on the straight line between them).
const WIPE_POINTS = 24;
/// One stretch of the view a wipe's edge runs over: from `from` to `to` (px, in the view).
export type WipeSpan = { from: number; to: number };

/// The stretches a wipe's edge runs over: the boxes that change, merged where they touch or overlap and
/// clipped to the view (`top`, `bottom`), top to bottom. The rows between them that did not change are
/// left out of the run: the edge crossing them changed nothing on screen, so a fold whose changes sat
/// apart (the summary up top, the answer below the kept steers) played as two or three motions with
/// stills between them (the fold fuzzer: 78 of 500 seeds). Over the spans it changes something on every
/// frame, one motion. Never empty: with nothing in the view, a 1 px run where the first box starts.
export function wipeSpans(boxes: { top: number; height: number }[], top?: number, bottom?: number): WipeSpan[] {
  const sorted = boxes
    .map((box) => ({
      from: top === undefined ? box.top : Math.max(top, box.top),
      to: bottom === undefined ? box.top + box.height : Math.min(bottom, box.top + box.height),
    }))
    .filter((span) => span.to > span.from)
    .sort((a, b) => a.from - b.from);
  const spans: WipeSpan[] = [];
  for (const span of sorted) {
    const last = spans.at(-1);
    if (last && span.from <= last.to + WIPE_SPAN_JOIN_PX) last.to = Math.max(last.to, span.to);
    else spans.push({ ...span });
  }
  if (spans.length) return spans;
  const at = Math.min(...boxes.map((box) => box.top), bottom ?? Infinity);
  return [{ from: Number.isFinite(at) ? at : 0, to: (Number.isFinite(at) ? at : 0) + 1 }];
}

/// Rows closer than this are one stretch of a wipe's run: a gap a frame's step crosses anyway.
const WIPE_SPAN_JOIN_PX = 8;

/// Where the edge is (px, in the view) once it has run `along` (0 to 1) of the spans' length.
export function wipeEdge(spans: WipeSpan[], along: number, up = false): number {
  const total = spans.reduce((sum, span) => sum + span.to - span.from, 0);
  let left = Math.min(1, Math.max(0, up ? 1 - along : along)) * total;
  for (const span of spans) {
    const length = span.to - span.from;
    if (left <= length) return span.from + left;
    left -= length;
  }
  return spans.at(-1)!.to;
}

/// How far along the spans (0 to 1) the edge reaches `y`; the inverse of `wipeEdge`.
export function wipeReach(spans: WipeSpan[], y: number, up = false): number {
  const total = spans.reduce((sum, span) => sum + span.to - span.from, 0);
  let before = 0;
  for (const span of spans) {
    if (y < span.to) {
      before += Math.max(0, y - span.from);
      break;
    }
    before += span.to - span.from;
  }
  const along = total > 0 ? Math.min(1, before / total) : 0;
  return up ? 1 - along : along;
}

/// A clip that hides `top` px of a box's top and nothing past its other edges.
const clipTop = (top: number) => `inset(${top}px -4096px -4096px -4096px)`;
/// The reader's gestures that end `defer`'s hold. Scrolls alone are not among them: the view scrolls
/// itself to keep the bottom pinned.
const READER_GESTURES = ["wheel", "touchstart", "keydown", "pointerdown"] as const;

/// Plays a replace look (`snapshot`, `wipe`, `sprout`, `defer`): nothing slides. Each row that moved is
/// drawn where it lands from the first frame, the rows the swap added where they land; over them, the
/// old frame is held where it was drawn (a snapshot of each moved row, a copy of each row the swap took
/// away), and the two frames trade places in place on one clock. Rows that did not move are drawn as they
/// are. As in `playTurnEnd`, each placement pass (a row mounted, the pinned bottom's scroll) reads every
/// place again and plays on from the same clock, so the old frame stays where the reader saw it.
function playReplace(
  thread: HTMLElement,
  capture: TurnEndCapture,
  look: TurnEndLook,
  scroller?: HTMLElement | null,
): TurnEndFold | undefined {
  const fold: TurnEndFold = { animations: new Set(), copies: new Set() };
  const View = thread.ownerDocument.defaultView;
  const timeline = thread.ownerDocument.timeline;
  const now = () => (typeof timeline?.currentTime === "number" ? timeline.currentTime : performance.now());
  const settleMs = settle(thread).ms;
  const ms = look === "snapshot" ? settleMs : look === "sprout" ? SPROUT_TRAVEL_MS + SPROUT_FADE_MS : WIPE.ms;
  const edgeAt = curveProgress(WIPE.easing) ?? ((x: number) => x);
  const was = new Map(capture.rows.filter((row) => !row.copy).map((row) => [row.id, row]));
  const gone = capture.rows.filter((row) => row.copy);
  /// The old frame: each element, and the top it was drawn at (in the view, as `layoutTops`).
  const old = new Map<HTMLElement, number>([
    ...gone.map((row) => [row.copy!, row.top] as const),
    ...[...was.values()].filter((row) => row.snapshot).map((row) => [row.snapshot!, row.top] as const),
  ]);
  /// When the swap starts: the first painted frame, `defer`'s hold after it, or the reader's gesture.
  let startsAt: number | undefined;
  let hold = look === "defer" ? DEFER_MS : 0;
  /// The edge's run, in the view: fixed at the first pass, over what changes (`spans`, the boxes that
  /// change merged, the rows between them that stay skipped). `up`: it runs from the bottom up, when the
  /// rows that move go down more than up, so it reaches most moved rows' new place before their old one.
  let edge: { spans: WipeSpan[]; up: boolean } | undefined;
  const played = new Map<HTMLElement, { key: string; animations: Animation[] }>();
  const toStart = () => (startsAt === undefined ? hold : startsAt - now());
  const arm = () => {
    clearTimeout(fold.timer);
    fold.timer = setTimeout(() => settleTurnEnd(thread, fold), Math.max(0, toStart() + ms + 50));
  };
  const drop = (element: HTMLElement) => {
    for (const animation of played.get(element)?.animations ?? []) {
      animation.cancel();
      fold.animations.delete(animation);
    }
    played.delete(element);
  };
  /// Plays `frames` on `element` on the swap's clock, unless what it plays has not changed (`key`), or
  /// the box it plays over is outside the view (`seen`, read by the caller with the places: a rect read
  /// here, between the `animate()` writes, would force a style pass per row, chat-render-pipeline R2).
  ///
  /// The view test is here, with the key test, rather than at each call site: this is the one door to
  /// `element.animate` in this path, so a call site added later cannot animate a row the reader cannot
  /// see. It comes before `drop` below, so what is already running is left to run out instead of being
  /// cancelled part way -- every keyframe set here ends at the new frame drawn whole and the old gone,
  /// which is the final state anyway, so a row carried out of the view finishes there quietly.
  const play = (
    element: HTMLElement,
    key: string,
    seen: boolean,
    frames: () => [Keyframe[], KeyframeAnimationOptions][],
  ) => {
    if (!seen || played.get(element)?.key === key) return;
    drop(element);
    const animations = frames().map(([keyframes, timing]) => {
      const animation = element.animate(keyframes, {
        duration: ms,
        fill: "backwards",
        ...timing,
        delay: (timing.delay ?? 0) + toStart(),
      });
      fold.animations.add(animation);
      return animation;
    });
    played.set(element, { key, animations });
  };
  let inserted = false;
  const pass = () => {
    const nodes = [...mounted(thread)];
    if (!inserted) {
      inserted = true;
      const below = nodes[0] ?? null;
      for (const element of old.keys()) {
        thread.insertBefore(element, below);
        fold.copies.add(element);
      }
    }
    const tops = layoutTops(nodes);
    const layers = [...old.keys()].filter((element) => fold.copies.has(element));
    const layerTops = layoutTops(layers);
    const heights = nodes.map((node) => node.offsetHeight);
    const layerHeights = layers.map((element) => element.offsetHeight);
    const view = scroller?.getBoundingClientRect();
    // The new frame's rows that change: the ones the swap added and the ones that moved. A kept row that
    // did not move is the same in both frames, and so is its snapshot, which goes.
    const fresh: { node: HTMLElement; top: number; height: number }[] = [];
    const still = new Set<HTMLElement>();
    let travel = 0;
    nodes.forEach((node, index) => {
      const before = was.get(node.dataset.rowId!);
      if (before && Math.abs(before.top - tops[index]!) < 0.5 && !played.has(node)) {
        if (before.snapshot) still.add(before.snapshot);
        return;
      }
      if (before) travel += tops[index]! - before.top;
      fresh.push({ node, top: tops[index]!, height: heights[index]! });
    });
    // A moved row's new place, by its snapshot: the old copy stays whole until the edge has drawn the row
    // there, so the row is drawn in at least one place on every frame (in both for a moment, never in
    // neither, whichever way it moved).
    const lands = new Map<HTMLElement, { top: number; height: number }>();
    for (const box of fresh) {
      const snapshot = was.get(box.node.dataset.rowId!)?.snapshot;
      if (snapshot) lands.set(snapshot, box);
    }
    const stale: { element: HTMLElement; top: number; height: number; lands?: { top: number; height: number } }[] = [];
    layers.forEach((element, index) => {
      if (still.has(element)) {
        drop(element);
        element.remove();
        fold.copies.delete(element);
        return;
      }
      // Held where it was drawn, whatever the view did since.
      const drawn = old.get(element)!;
      element.style.translate = `0 ${drawn - layerTops[index]!}px`;
      stale.push({ element, top: drawn, height: layerHeights[index]!, lands: lands.get(element) });
    });
    if (!edge) {
      const boxes = [...fresh, ...stale];
      if (boxes.length === 0) return;
      edge = { spans: wipeSpans(boxes, view?.top, view?.bottom), up: travel > 0 };
    }
    const { spans, up } = edge;
    /// Where a box of the view crosses the edge's run, as a fraction of it (0 where it starts, 1 at its end).
    const reach = (y: number) => wipeReach(spans, y, up);
    /// The edge at `step` of WIPE_POINTS. The run is the part of the view that changes, so a box past
    /// the view's edge or its spans' ends is still partly clipped when the edge stops there: the last
    /// point puts the edge past every box (`top`, `height`), so the new frame ends wholly drawn and the
    /// old wholly gone on the edge's last step, with nothing left for the animation's end to settle.
    const edgeY = (step: number, top: number, height: number) => {
      const y = wipeEdge(spans, edgeAt(step / WIPE_POINTS), up);
      if (step < WIPE_POINTS) return y;
      return up ? Math.min(y, top) : Math.max(y, top + height);
    };
    /// A box's clip at edge `y`: the new frame shows on the side the edge has passed, the old on the other.
    const clipAt = (fresh: boolean, top: number, height: number, y: number) => {
      const above = Math.min(height, Math.max(0, y - top));
      const below = Math.min(height, Math.max(0, top + height - y));
      // Running down, the edge has passed what is above it; running up, what is below it.
      return fresh === !up ? clipBottom(below) : clipTop(above);
    };
    /// Whether a box meets the view, edge included, as `captureTurnEnd`'s own `seen`. A view of no
    /// height has not been laid out yet, so everything counts as seen there (`unmeasured`).
    /// Nothing slides in a replace look -- every row is drawn where it lands from the first frame -- so
    /// a box is the whole of what it ever covers, and one outside the view is a swap the reader never
    /// sees happen. It takes its final state instead: the new frame drawn whole, unclipped, full ink.
    /// `wipeSpans` above still read every box, in view or not: the edge's run is the part of the view
    /// that changes, and narrowing it to the seen boxes alone would change where the edge starts and
    /// stops, so the rows the reader IS looking at would animate differently than they do today. What
    /// the guard changes is which rows animate, never the edge they animate against.
    const boxSeen = (top: number, height: number) =>
      !view || view.height === 0 || (top + height >= view.top && top <= view.bottom);
    // `snapshot`: the new frame comes in on the ease-out as the old goes on the ease-in, all on one clock.
    // `sprout`: each box crossfades over the micro step once the edge reaches its middle.
    // `wipe`, `defer`: each box is clipped at the edge, the new above it and the old below it.
    for (const { node, top, height } of fresh) {
      const key = `${Math.round(top)} ${Math.round(height)}`;
      // Out of view the row is simply drawn where it lands, whole: no fade, no clip, nothing played
      // (`play` above). Not latched: a later placement pass animates it once it is seen. The reader's
      // scroll never does: it ends the swap (`endOnReaderScroll` below).
      const seen = boxSeen(top, height);
      // A row still playing its own entrance keeps its fade; the clip alone is the swap's. Its class
      // stays once the entrance ended, so the entrance itself is what counts.
      const enters =
        node.matches(".acpmux-row--enter, .acpmux-row--message-enter") &&
        node.getAnimations().some((animation) => animation.playState === "running" || animation.playState === "paused");
      if (look === "snapshot") {
        if (!enters) play(node, key, seen, () => [[[{ opacity: 0 }, { opacity: 1 }], { easing: MOTION_EASE_OUT }]]);
      } else if (look === "sprout") {
        const delay = reach(top + height / 2) * SPROUT_TRAVEL_MS;
        if (!enters)
          play(node, key, seen, () => [
            [[{ opacity: 0 }, { opacity: 1 }], { delay, duration: SPROUT_FADE_MS, easing: MOTION_EASE_OUT }],
          ]);
      } else
        play(node, key, seen, () => [
          [
            Array.from({ length: WIPE_POINTS + 1 }, (_, step) => ({
              clipPath: clipAt(true, top, height, edgeY(step, top, height)),
            })),
            { easing: "linear" },
          ],
        ]);
    }
    for (const { element, top, height, lands } of stale) {
      // The old frame's copy of a row no one can see: its final state is gone, so it goes now, the way
      // a copy whose row never moved goes (`still` above) -- `drop`, out of the thread, out of
      // `fold.copies`. Left drawn with no animation it would hold the old frame at full ink for the
      // fold's whole length and then vanish in one frame. The edge was already measured over every
      // box, this one included, so the rows in view keep the run they have today.
      // A copy already playing is left alone: its fade ends at no ink and its clip at the old frame
      // gone, so it reaches that same final state on its own, and taking it out mid-animation would
      // drop the old frame in one frame where the reader may yet scroll back to it.
      if (!played.has(element) && !boxSeen(top, height)) {
        drop(element);
        element.remove();
        fold.copies.delete(element);
        continue;
      }
      const key = `${Math.round(top)} ${Math.round(height)}`;
      // An unseen copy went above instead of taking a final state where it stands, so one that reaches
      // here is in the view, or is already playing and is left to run out to the same end.
      const seen = boxSeen(top, height) || played.has(element);
      if (look === "snapshot")
        play(element, key, seen, () => [[[{ opacity: 1 }, { opacity: 0 }], { easing: EASE_IN, fill: "both" }]]);
      else if (look === "sprout") {
        const delay = reach(top + height / 2) * SPROUT_TRAVEL_MS;
        play(element, key, seen, () => [
          [[{ opacity: 1 }, { opacity: 0 }], { delay, duration: SPROUT_FADE_MS, easing: EASE_IN, fill: "both" }],
        ]);
      } else
        play(element, key, seen, () => [
          [
            Array.from({ length: WIPE_POINTS + 1 }, (_, step) => {
              const y = edgeY(step, top, height);
              // On the last step the row is drawn in its new place, wherever that is: the old copy goes.
              // A row that lands where its copy is drawn is drawn once either side of the edge, and one
              // that lands wholly past the run's far end (out of view) is not drawn in view either way:
              // both copies go with the edge. Held whole to the last step, such a copy (14 px in view)
              // went in one frame 60 ms after the edge stopped (wipe seed 193 on cmux#50751).
              const drawnThere =
                !lands ||
                step === WIPE_POINTS ||
                (Math.abs(lands.top - top) < 0.5 && Math.abs(lands.height - height) < 0.5) ||
                (up ? lands.top + lands.height <= spans[0]!.from : lands.top >= spans.at(-1)!.to) ||
                (up ? y <= lands.top : y >= lands.top + lands.height);
              return { clipPath: drawnThere ? clipAt(false, top, height, y) : clipTop(0) };
            }),
            { easing: "linear", fill: "both" },
          ],
        ]);
    }
  };
  pass();
  if (fold.animations.size === 0) {
    settleTurnEnd(thread, fold);
    return undefined;
  }
  thread.setAttribute(TURN_END_ATTR, look);
  const firstFrame = View?.requestAnimationFrame(() => {
    startsAt = now() + hold;
    // The clock starts with the first painted frame: every animation plays again on it.
    for (const element of Array.from(played.keys())) drop(element);
    pass();
    arm();
  });
  // `defer`: the reader's first gesture starts the swap now.
  const page = thread.ownerDocument;
  const gesture = () => {
    for (const name of READER_GESTURES) page.removeEventListener(name, gesture, true);
    if (toStart() <= 0) return;
    hold = 0;
    startsAt = now();
    for (const element of Array.from(played.keys())) drop(element);
    pass();
    arm();
  };
  if (look === "defer") for (const name of READER_GESTURES) page.addEventListener(name, gesture, true);
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
  // The reader's own scroll ends the swap at once, as it ends `playTurnEnd`'s fold (rule 4): every row
  // drawn where it lands, the old frame's copies gone. Played on, the `scroll` pass below read the
  // scroll as a new place for every row (its key is a top in the view) and started each one's wipe
  // again, on rows the reader scrolled to and rows it carried past the edge (the motion gate's
  // `offscreen-start` residual). Registered first, so the reader's scroll settles the swap before
  // that pass runs: `settleTurnEnd` takes the pass's listener off, and a listener taken off during a
  // dispatch is not called. What still reaches the pass is the view's own scroll (the bottom kept
  // pinned), which plays on from the same clock.
  const unscroll = endOnReaderScroll(thread, scroller, fold);
  scroller?.addEventListener("scroll", pass, { passive: true });
  fold.stop = () => {
    if (firstFrame !== undefined) View?.cancelAnimationFrame(firstFrame);
    observer?.disconnect();
    scroller?.removeEventListener("scroll", pass);
    unscroll();
    for (const name of READER_GESTURES) page.removeEventListener(name, gesture, true);
  };
  arm();
  return fold;
}

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
  // Out of the reader's view there is nothing to play: its caller has settled what the turn's end
  // settles (the fold before it, the follow motion, the tail glide) and the swap is already drawn.
  if (capture.silent || capture.sessionId !== sessionId || foldMs(thread) <= 0) return undefined;
  // Across a message the person sent, the crossing fold's one transition (`TurnEndCross`), or for
  // `snap` none: the swap stays as it rendered, in one frame.
  const cross = foldCrossesPerson(capture) ? turnEndCrossTiming(thread) : undefined;
  if (foldCrossesPerson(capture) && !cross) return undefined;
  const look = cross ? "fade" : turnEndLook(thread);
  if (REPLACE_LOOKS.has(look)) return playReplace(thread, capture, look, scroller);
  const recapLook = turnEndRecap(thread);
  const subagentLook = turnEndSubagent(thread);
  const { ms: settleMs, easing: settleEasing } = cross
    ? { ms: cross.moveMs, easing: cross.easing }
    : lookTiming(look, settle(thread));
  // The fold's one clock: the settle's length, its curve flattened as a pass finds a longer move
  // (turnEndFoldTiming). Rows the virtualizer mounts above after the swap move the rows under them
  // again, so the first pass's moves are not the longest (turn-transition-jumps `tool-group`: 2 px at
  // the first pass, 77 px at the next). When the curve changes the clock starts again from that pass,
  // and every row and copy goes on from where it was drawn in the last painted frame (its place and
  // ink then), never from the swap's: nothing is drawn back and no fading copy comes back up.
  // `capped` alone changes the length, as its move is read (cappedMs).
  let ms = settleMs;
  let easing = settleEasing;
  let grew = false;
  const fold: TurnEndFold = { animations: new Set(), copies: new Set() };
  // What the fold moves, declared while it plays (the contract's `turn-end`, motionContract.ts): every
  // box it animates, filled in as the passes find them, and `strict`, so a box the fold does not play
  // on is a shift even if the fold pushed it -- "No row above it moves, no row below it is pushed or
  // pulled". The judge reads boxes after transforms, so these moves need declaring; a box that moved
  // because the layout under it changed is not in here and is flagged. One map entry while it plays.
  const played: Element[] = [];
  // Except a row above everything the swap changed that the fold carries *up* (`risen`). The fold
  // plays whatever the layout hands it, so declaring every box it animates declared the jump too: a
  // turn that appended a row at its end lifted every row above it, and the fold slid them there
  // gracefully, so the judge saw a declared move and the gate read 0 (measured on the judged
  // scenario, base: the rows above rose 208 px, every frame of it marked targeted by this
  // declaration). Coming *down* is the fold's own doing -- its work folds away and "everything above
  // it comes down to meet the folded line" -- and stays declared; rising means the end added height
  // under rows that were already drawn, which is the thing the contract forbids ("No row above it
  // moves"), whether or not the fold made it pretty. `strict` and the scope are unchanged.
  const risen = new Set<Element>();
  fold.release = declareMove({
    event: "turn-end",
    scope: "targets",
    targets: played,
    strict: true,
    by: "turn-end fold",
  });
  // The fold's clock starts with the first frame that paints it. A pass before that frame runs (the
  // rows measured and placed again in the long frame the swap renders) plays from the start, so the
  // first painted frame is the fold's first, never most of the way there in one step.
  const View = thread.ownerDocument.defaultView;
  const timeline = thread.ownerDocument.timeline;
  const now = () => (typeof timeline?.currentTime === "number" ? timeline.currentTime : performance.now());
  // Exit before move (exitLead.ts): the copies of the rows the swap took away fade out over the exit
  // lead, from the first painted frame, and every move (the rows that stay, the copies, their clips, the
  // rows that come in) starts when it ends, held at its start until then. A fold that takes nothing
  // away has no lead. Leo, 2026-11-21: "that text hiding as it travels so it doesnt show weird overlays
  // is the big one ... we must hide text faster and sooner".
  // `wait` holds the work in sight first; `crossfade` and `cascade` fade the copies on the move's clock.
  const lead = !capture.rows.some((row) => row.copy)
    ? 0
    : look === "wait"
      ? WAIT_HOLD_MS
      : look === "crossfade" || look === "cascade" || ridesSheet(look)
        ? 0
        : cross
          ? cross.fadeMs
          : exitLeadMs(ms, 1, thread);
  /// The first painted frame (the exit's clock), and when the move's clock starts.
  let startedAt: number | undefined;
  let movesAt: number | undefined;
  const firstFrame = View?.requestAnimationFrame(() => {
    startedAt = now();
    movesAt = startedAt + lead;
    // The fold's clock starts here, so its backstop does too: armed only at the swap, a first frame
    // that came late (a busy main thread, 130 ms and more: entranceClock.ts) left the timer to finish
    // the fold part way, its rest in one jump (Leo, 2026-11-21: "sometimes animations sprint for no
    // reason"). A hidden page paints no frame and keeps the swap's timer.
    if (fold.timer !== undefined) arm(lead);
  });
  /// How long until the move starts (negative once it runs).
  const toMove = () => (movesAt === undefined ? lead : movesAt - now());
  /// How long past the move's end the fold runs: the latest hold of a row that arrives, whose fade
  /// starts when the kept rows have cleared its box and takes the move's length from there. The
  /// backstop waits for it: armed at the move's end alone, it finished a held fade part way, the
  /// reply from 28% ink to full in one step (cmux#48689 F2).
  let tail = 0;
  /// A row arrived playing its own entrance, so the fold drew nothing on it. The fold still runs:
  /// later passes ease that row to its place as the rows above settle (a turn of words alone has no
  /// other animation at its first pass, and a fold dropped there let the reply step 35 px in a frame).
  let entering = false;
  // `wait`: until the move starts, negative once it runs, so a pass mid-move arms what is left.
  const arm = (wait = toMove()) => {
    clearTimeout(fold.timer);
    fold.timer = setTimeout(() => settleTurnEnd(thread, fold), Math.max(0, wait + ms + tail + 50));
  };
  const play = (node: HTMLElement, keyframes: Keyframe[], timing: KeyframeAnimationOptions = {}) => {
    // On the fold's clock: a pass after its first frame starts each animation part way, in step.
    const delay = (timing.delay ?? 0) + toMove();
    const fill: FillMode | undefined =
      lead > 0 ? (timing.fill === "forwards" || timing.fill === "both" ? "both" : "backwards") : timing.fill;
    const animation = node.animate(keyframes, { duration: ms, easing, ...timing, delay, ...(fill && { fill }) });
    fold.animations.add(animation);
    // A row the fold carries up from above everything the swap changed is played, never declared.
    if (risen.has(node)) {
      const at = played.indexOf(node);
      if (at >= 0) played.splice(at, 1);
    } else if (!played.includes(node)) played.push(node);
    return animation;
  };
  /// A copy's ink going to 0 on the exit's clock, `offset` ms into it (a stagger's step). A copy whose
  /// clock started again (`starts` has its drawn ink) goes on from that ink over the exit left.
  // With no lead (the gallery's `none` arm, the look before) the copy fades on the move's own clock,
  // gone by 60% of it, as #41078 had it.
  const exitMs = look === "crossfade" || look === "cascade" || ridesSheet(look) ? ms : lead > 0 ? lead : ms * 0.6; // motion-allow: the `none` arm's share of the settle
  /// `wait`: the copies keep their ink through the hold, and fade over the house exit lead at its end.
  /// `sheet` and `water`: the copies keep their ink over the move's first half, riding in under the line.
  const exitFrom =
    look === "wait" ? Math.max(0, lead - exitLeadMs(settleMs, 1, thread)) : ridesSheet(look) ? ms / 2 : 0;
  /// `morph`'s card, behind the rows, and the geometry it plays (to play it again only when that changes).
  let card: { element: HTMLElement; key: string; animations: Animation[] } | undefined;
  const exit = (copy: HTMLElement, offset: number) => {
    const drawn = starts.get(copy)?.opacity;
    const since = startedAt === undefined ? 0 : now() - startedAt;
    const timing: KeyframeAnimationOptions =
      drawn === undefined
        ? { duration: Math.max(1, exitMs - offset), delay: offset - since }
        : { duration: Math.max(1, exitMs - Math.max(offset, since)), delay: 0 };
    const animation = copy.animate([{ opacity: drawn ?? 1 }, { opacity: 0 }], {
      ...timing,
      easing: EXIT_EASING,
      fill: "both",
    });
    fold.animations.add(animation);
    if (!played.includes(copy)) played.push(copy);
    return animation;
  };
  // The rows the swap kept, by id; a row it took away left its copy, and its id may come back as
  // a new row (the edits card), which comes in as one.
  const was = new Map(capture.rows.filter((row) => !row.copy).map((row) => [row.id, row]));
  const gone = capture.rows.filter((row) => row.copy);
  const goneByCopy = new Map(gone.map((row) => [row.copy!, row]));
  const crossed = new Set(gone.filter((row) => row.crosses).map((row) => row.id));
  const moving = new Map<HTMLElement, Moving>();
  const copyMoves = new Map<HTMLElement, Moving>();
  /// Where each row's or copy's motion on the current clock starts (a top in the view, as `tops`),
  /// and its ink then: the swap's for the first clock, the drawn ones when the curve changes.
  const starts = new Map<HTMLElement, { top?: number; opacity?: number; shown?: number }>();
  /// Each row's and copy's laid-out top at the last pass: with its translate then, where it was drawn.
  const laid = new Map<HTMLElement, number>();
  /// The copies taken out before the fold ended (a row came in under them, below).
  const dropped = new Set<HTMLElement>();
  /// The copies put in their final state (no ink) because their whole travel was out of the view.
  /// Latched, unlike a row: a row out of sight is drawn at its place, which is where it belongs
  /// whenever the reader reaches it, so a later pass may still animate what is left of its path. A
  /// copy's final state is gone, and a reader who scrolls to its place must find the swap there, not
  /// a row the turn took away fading in from full ink.
  const unseen = new Set<HTMLElement>();
  // `anchored`: the kept row the reader is on, the one drawn nearest the view's center before the swap.
  const anchor =
    look === "anchored" && scroller
      ? (() => {
          const view = scroller.getBoundingClientRect();
          const center = view.top + scroller.clientHeight / 2;
          const away = (row: Drawn) => {
            const bottom = row.top + (row.height ?? 0);
            return row.top <= center && center <= bottom
              ? 0
              : Math.min(Math.abs(row.top - center), Math.abs(bottom - center));
          };
          return [...was.values()].sort((a, b) => away(a) - away(b))[0];
        })()
      : undefined;
  /// The subagent block's snapshots (`swap`), by the row each pictures; in before the rows, as the copies.
  const snapshots = new Map<string, HTMLElement>();
  let snapshotsIn = subagentLook !== "swap";
  /// The view as this pass read it, taken once with the places: a rect read between the `animate()`
  /// writes below would force a style pass per row (chat-render-pipeline R2). Undefined until the
  /// first pass, and on a pane with no scroller.
  let viewNow: DOMRect | undefined;
  /// Whether a box's band meets the view, edge included, as `captureTurnEnd`'s own `seen`: an empty
  /// slot right at the edge is where the reader is looking. A view of no height has not been laid out
  /// (a pane measured before its first layout), so everything counts as seen there, as `unmeasured`.
  const bandSeen = (top: number, height: number) =>
    !viewNow || viewNow.height === 0 || (top + height >= viewNow.top && top <= viewNow.bottom);
  /// Whether the box an animation would START on meets the view: where the row is drawn at that
  /// moment, not where it lands and not the band between.
  ///
  /// This is rule 1 of docs/design/transcript-animation-rules.md as written -- "a motion starts only on
  /// a row whose box meets the scroller's box WHEN IT STARTS" -- and it is also exactly what the
  /// detector measures (`strayStarts` reads `start.top`/`start.bottom`, the box at the start frame). A
  /// looser "seen anywhere along the sweep" test passes almost every start the detector flags, because
  /// most of them are rows sliding in from outside the view: measured over the fuzzer corpus it took
  /// `offscreen-start` down only about a tenth, where this test is what the zero-stray gate needs.
  ///
  /// A row that starts outside and lands inside is therefore drawn at its landing place, whole, with no
  /// animation -- the doc's "drawn in its final state". The reader who scrolls to it finds it where it
  /// belongs rather than sliding in from a place he never saw it in.
  ///
  /// `captureTurnEnd` drops a fold no part of which is seen (`silent`). This is the same rule one row
  /// at a time, for the rows of a fold that does play; `restart` below is where it is applied, and
  /// says why there.
  const startSeen = (from: number, height: number) => bandSeen(from, height);
  const pass = () => {
    let nodes = [...mounted(thread)];
    // Scrolled before any place is read, so the pass plays every row from where it was to where it is
    // with the anchor's move already taken out (a scroll it causes runs this pass again, finding none).
    if (anchor && scroller) {
      const node = nodes.find((n) => n.dataset.rowId === anchor.id);
      const moved = node ? node.getBoundingClientRect().top - (starts.get(node)?.top ?? anchor.top) : 0;
      if (node && !moving.has(node) && Math.abs(moved) > 0.5) {
        scroller.scrollTop += moved;
        nodes = [...mounted(thread)];
      }
    }
    if (gone.length > 0 && fold.copies.size === 0 && copyMoves.size === 0 && dropped.size === 0) {
      // The rows that went: each copy goes in before the rows that stay, so they draw over it.
      const below = nodes[0] ?? null;
      for (const row of gone) {
        thread.insertBefore(row.copy!, below);
        fold.copies.add(row.copy!);
      }
    }
    if (!snapshotsIn) {
      snapshotsIn = true;
      const below = nodes[0] ?? null;
      for (const row of was.values())
        if (row.snapshot) {
          thread.insertBefore(row.snapshot, below);
          fold.copies.add(row.snapshot);
          snapshots.set(row.id, row.snapshot);
        }
    }
    // Every place is read before anything plays, so a pass lays the page out once.
    const tops = layoutTops(nodes);
    // Read with the places, for `bandSeen` below: what the reader can see of this pass.
    viewNow = scroller?.getBoundingClientRect();
    const snapshotTops = layoutTops([...snapshots.values()]);
    /// Where each row is DRAWN in this pass (its rect, so a translate still running counts), against
    /// `tops`, where it is laid out. Taken here, in the pass's read phase with every other
    /// measurement, so this costs no layout of its own; `restart` says why it needs it.
    const drawnTop = new Map<HTMLElement, number>();
    for (const node of nodes) drawnTop.set(node, node.getBoundingClientRect().top);
    for (const snapshot of snapshots.values()) drawnTop.set(snapshot, snapshot.getBoundingClientRect().top);
    // The lowest row the swap kept, where it was drawn then, and how far from its place it starts. A
    // row that comes in under it (the next turn's prompt, its live line and reply, arriving while the
    // fold plays) moves with it: placed where it lands and drawn there at once, it sat over the kept
    // row still sliding into place, by as much as that row's move (Leo, 2026-11-18, a coordinator's
    // chat: "not sure if we've fixed this doubled up looking ass text fixed yet";
    // agent-pane-stream-row-overlap, the replayed coordinator chat: a reply 242 px from its place over
    // the next turn's first tool row, 158 px).
    let lowest = -Infinity;
    let lowestWas = -Infinity;
    nodes.forEach((node, index) => {
      const before = was.get(node.dataset.rowId!);
      if (before && tops[index]! > lowest) {
        lowest = tops[index]!;
        lowestWas = before.top;
      }
    });
    // A row drawn across the person's message arrives too, wherever it lands: carried, it ran through
    // the steer's text as the two swapped places; it holds at no ink until nothing moving crosses it.
    const arrives = (node: HTMLElement, index: number) =>
      !was.has(node.dataset.rowId!) && (tops[index]! > lowest || crossed.has(node.dataset.rowId!));
    // The ended turn's own footer (direct.ts `summary-TURN`) comes in with the swap where its live line was,
    // and takes only that line's place, not its work's: a turn that ended on its calls, no answer under
    // them, lost their copy on the fold's first frame, and the view stood blank 108 ms while the rows above
    // fell in (the fold matrix's `ends-on-tool` cell; Leo, 2026-11-22: "tool calls at various times and
    // turn ends at various").
    const nextTurn = nodes.some((node, index) => arrives(node, index) && !node.dataset.rowId!.startsWith("summary-"));
    // The copies of what the ended turn drew under its last kept row (its live line) go once the next
    // turn's rows come in there: those rows take that place, and a copy fading under them drew its
    // text through theirs (the same replay: the new tool row over the old "Thinking" line, 107 px).
    if (Number.isFinite(lowest) && nodes.some(arrives))
      for (const row of gone)
        if (row.top > lowestWas && fold.copies.has(row.copy!) && (nextTurn || row.id === LIVE_LINE)) {
          for (const animation of copyMoves.get(row.copy!)?.animations ?? []) {
            animation.cancel();
            fold.animations.delete(animation);
          }
          copyMoves.delete(row.copy!);
          fold.copies.delete(row.copy!);
          dropped.add(row.copy!);
          row.copy!.remove();
        }
    const copies = gone.map((row) => row.copy!).filter((copy) => fold.copies.has(copy));
    // The copies' drawn tops, with the rows' above: still the pass's read phase, before anything plays.
    for (const copy of copies) drawnTop.set(copy, copy.getBoundingClientRect().top);
    const copyTops = layoutTops(copies);
    // Each box's height and paddings, read with the places (only while a copy shows): where each row's
    // and copy's text draws (`coverClip`).
    const boxes = copies.length ? [...nodes, ...copies].map(boxOf) : [];
    // Each row's and copy's height, read with the places: the writes below (each `animate()`) dirty
    // style, so a height read between them forced a style pass per row (chat-render-pipeline R2).
    // Translate, clip and opacity never change a height, so these are the heights the loop read.
    const heights = boxes.length ? boxes.slice(0, nodes.length).map((box) => box.height) : nodes.map(heightOf);
    const copyHeights = boxes.length ? boxes.slice(nodes.length).map((box) => box.height) : copies.map(heightOf);
    // The top of everything the swap changed: the highest row it took away (where it was drawn) or
    // added (where it lands). What sits whole above this line is not the turn's; the fold may carry
    // it down as the work folds away, and may not carry it up (`risen`).
    let changedTop = Number.POSITIVE_INFINITY;
    for (const row of gone) changedTop = Math.min(changedTop, row.top);
    nodes.forEach((node, index) => {
      if (!was.has(node.dataset.rowId!)) changedTop = Math.min(changedTop, tops[index]!);
    });
    turnEndFoldPerf.passes += 1;
    turnEndFoldPerf.rowsRead += nodes.length + copies.length;
    turnEndFoldPerf.mostRowsRead = Math.max(turnEndFoldPerf.mostRowsRead, nodes.length + copies.length);
    /// Each row's path on this clock, for the copies under or over it.
    const paths: CoverPath[] = [];
    // The folded line: the first row the swap added (the turn's "Worked for"). Copies tuck under it.
    const line =
      tops.find((_, index) => was.get(nodes[index]!.dataset.rowId!)?.replacesHeader) ??
      tops.find((_, index) => !was.has(nodes[index]!.dataset.rowId!));
    const startTop = (node: HTMLElement, fallback: number) => starts.get(node)?.top ?? fallback;
    // `edge`: a kept row that starts wholly out of the view (above or below it) starts just past the
    // view's edge instead, stacked on the row next to it, so nothing travels farther than it is seen; a
    // row already moving keeps its start. Read before anything plays.
    if (look === "edge" && scroller) {
      const view = scroller.getBoundingClientRect();
      const heights = nodes.map((node) => node.offsetHeight);
      const kept = (index: number) => {
        const before = was.get(nodes[index]!.dataset.rowId!);
        return before && !arrives(nodes[index]!, index) ? before : undefined;
      };
      let next: number | undefined;
      for (let index = nodes.length - 1; index >= 0; index -= 1) {
        const before = kept(index);
        if (!before) continue;
        const node = nodes[index]!;
        let from = startTop(node, before.top);
        if (!moving.has(node) && from + heights[index]! <= view.top && from < tops[index]!) {
          const nearest = Math.min(view.top, next ?? view.top) - heights[index]!;
          from = Math.min(tops[index]!, Math.max(from, nearest));
          starts.set(node, { ...starts.get(node), top: from });
        }
        next = from;
      }
      let previous: number | undefined;
      for (let index = 0; index < nodes.length; index += 1) {
        const before = kept(index);
        if (!before) continue;
        const node = nodes[index]!;
        let from = startTop(node, before.top);
        if (!moving.has(node) && from >= view.bottom && from > tops[index]!) {
          const nearest = Math.max(view.bottom, previous ?? view.bottom);
          from = Math.max(tops[index]!, Math.min(from, nearest));
          starts.set(node, { ...starts.get(node), top: from });
        }
        previous = from + heights[index]!;
      }
    }
    const longestMove = () => {
      let longest = 0;
      nodes.forEach((node, index) => {
        const before = was.get(node.dataset.rowId!);
        if (before) longest = Math.max(longest, Math.abs(startTop(node, before.top) - tops[index]!));
      });
      if ((look === "tuck" || look === "cascade") && line !== undefined)
        copies.forEach((copy) => {
          const row = goneByCopy.get(copy)!;
          longest = Math.max(longest, Math.abs(line - startTop(copy, row.top)));
        });
      return longest;
    };
    // From where each row now starts: a move too fast for the clock's curve flattens it, in the fold's
    // first frames only. A move past what the straight line fits keeps it: the curve is already
    // as flat as it goes, and the clock never starts again for it.
    const early = movesAt === undefined || now() - movesAt <= GROW_WINDOW_MS;
    const longest = early ? longestMove() : 0;
    // `glide` and `spring` keep their own curve whole: leaned to the frame bound, a long move ran on the
    // straight line, which is the look they are there to compare against.
    const ownCurve = look === "glide" || look === "spring" || look === "capped" || look === "water";
    const timing =
      look === "capped"
        ? early
          ? { ms: cappedMs(longest), easing }
          : undefined
        : early && !ownCurve && !foldFits(longest, ms, easing)
          ? turnEndFoldTiming(longest, settleMs, settleEasing)
          : undefined;
    grew = timing !== undefined && (timing.easing !== easing || Math.abs(timing.ms - ms) >= FRAME_MS);
    if (grew) {
      if (startedAt !== undefined) {
        // A frame has painted: each row and copy goes on from where it was drawn. All reads first.
        // Before the move starts (the exit lead) a clipped row is drawn as the first frame put it: its
        // clip stays the one captured then, never read back from what is drawn, which moved the reply's
        // clip 8 px on the fold's second frame and split the fold in two around the lead (fade seed 74
        // on cmux#50751).
        const moveRuns = movesAt !== undefined && now() >= movesAt;
        const drawn = [...moving.keys(), ...copyMoves.keys()].flatMap((node) => {
          const top = laid.get(node);
          if (top === undefined) return [];
          const style = (View ?? window).getComputedStyle(node);
          const y = style.translate === "none" ? 0 : Number.parseFloat(style.translate.split(" ")[1] ?? "") || 0;
          const captured = moving.get(node)?.clip;
          const clip = captured ? (moveRuns ? clippedBottom(node) : captured) : 0;
          const shown = clip > 0 ? top + y + node.offsetHeight - clip : undefined;
          return [{ node, top: top + y, opacity: Number.parseFloat(style.opacity), shown }];
        });
        for (const { node, top, opacity, shown } of drawn)
          starts.set(node, { top, opacity: Number.isFinite(opacity) ? opacity : undefined, shown });
        // The move's clock starts again from this pass, or where the exit ends if it has not yet.
        movesAt = Math.max(now(), movesAt ?? 0);
      }
      // The clock starts again from this pass: its end moves out with it.
      easing = timing!.easing;
      ms = timing!.ms;
      if (fold.timer !== undefined) arm();
    }
    const startsInView = (node: HTMLElement, from: number, height: number) => {
      const drawn = drawnTop.get(node);
      return (drawn === undefined || bandSeen(drawn, height)) && startSeen(from, height);
    };
    // Rows excluded from motion are already at their final places. Moving rows still need to
    // stay outside those boxes, just as ghosts do; the captured positions no longer bound them.
    const atRest = nodes.flatMap((node, index) => {
      const before = was.get(node.dataset.rowId!);
      if (!before || moving.has(node) || startsInView(node, startTop(node, before.top), heights[index]!)) return [];
      return [{ from: tops[index]!, to: tops[index]!, height: heights[index]!, padTop: 0, padBottom: 0 }];
    });
    const restart = (
      node: HTMLElement,
      store: Map<HTMLElement, Moving>,
      /// The band this animation covers: where the row starts, where it lands, and its height. A row
      /// that does not move gives its place for both. Required, so a call site added later cannot
      /// animate without saying what part of the page it animates over.
      band: { from: number; to: number; height: number },
      next: Moving,
      keyframes: () => Keyframe[][],
      timing: KeyframeAnimationOptions = {},
    ) => {
      /// Nothing plays on a row drawn outside the view at the moment it would start: the row is already laid out
      /// at its place, so not animating it IS its final state, drawn once, full ink (Leo, 2026-11-22:
      /// "i scroll down, some bullshit ABOVE folds...? and plays an animation!? so there's some
      /// bullshit animation where i dont expect it to be, which is horrendous").
      ///
      /// The gate is here rather than in `play` because it has to be decided before the cancel below.
      /// By the time `play` runs, `restart` has already cancelled whatever was running, so a gate there
      /// would leave a row that scrolled out mid-move with no animation at all: it would snap to its
      /// place, the same visual fault in another shape. Returning here instead leaves a running
      /// animation to run out, which lands right -- every keyframe set ends at `translate: 0`, the row's
      /// true place, and at full ink -- so a row carried out of the view finishes quietly where it
      /// belongs. What is skipped is only the START of a new animation on a row the reader cannot see.
      ///
      /// Nothing is latched: `pass()` runs again on every scroll and every placement, so a row scrolled
      /// into view mid-fold animates from that later pass, in step with the fold's clock (`play`'s
      /// negative delay), over what is left of its path.
      /// Two boxes have to meet the view, because `band.from` alone is not where the row is.
      /// `from` is `startTop(node, before.top)`: the top this row was captured at, in the view's
      /// coordinates of that moment. Only the anchor row is carried across a scroll (`scrollTop +=
      /// moved` above), so for every other row a reader's scroll leaves `before.top` stale by the
      /// distance he moved -- measured here at hundreds of pixels (a row tested at `from` 78 while it
      /// was drawn at -534). Testing the stale box let a fold animate rows far outside the view, which
      /// is the fault Leo reported.
      ///
      /// `drawnTop` is where the row is drawn in this pass, read with the other places so the pass
      /// still lays the page out once (never a rect per row between `animate()` writes:
      /// chat-render-pipeline R2).
      if (!startsInView(node, band.from, band.height)) return;
      const cover =
        store === moving && was.has(node.dataset.rowId!) && Math.abs(next.delta) >= 0.5
          ? coverClip({ ...band, padTop: 0, padBottom: 0 }, atRest, Math.max(0, next.clip ?? 0), 0)
          : undefined;
      next.covered = cover ? JSON.stringify(cover) : undefined;
      const last = store.get(node);
      if (
        !grew &&
        last &&
        Math.abs(last.delta - next.delta) < 0.5 &&
        last.fades === next.fades &&
        last.covered === next.covered &&
        Math.abs((last.clip ?? 0) - (next.clip ?? 0)) < 0.5 &&
        Math.abs((last.hold ?? 0) - (next.hold ?? 0)) < FRAME_MS
      )
        return;
      for (const animation of last?.animations ?? []) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      const frames = keyframes();
      // One clip combines the existing bottom reveal with the stationary row cover. Separate
      // clip animations replace one another, which would reopen the bottom while it moves.
      if (cover) {
        for (const sequence of frames) for (const frame of sequence) delete frame.clipPath;
        frames.push(cover);
      }
      next.animations = frames.map((sequence) => play(node, sequence, timing));
      store.set(node, next);
    };
    /// The rows that start clipped this pass: where each starts, the bottom it draws, its bottom at rest.
    const covers: { top: number; bottom: number }[] = [];
    /// Where each copy starts drawn (a top in the view, as `tops`).
    const copyStarts = copies.map((copy) => startTop(copy, goneByCopy.get(copy)!.top));
    // How far each kept row starts from its place (its move's distance), and the settle curve's
    // progress at a time fraction. A row that arrives holds at its place until no kept row's drawn box
    // overlaps it (sampled along the move), then fades in: the reply's ink starts there, not at the
    // move's end.
    const drift = nodes.map((node, index) => {
      const before = was.get(node.dataset.rowId!);
      return before && !arrives(node, index) ? startTop(node, before.top) - tops[index]! : 0;
    });
    const progressAt = curveProgress(easing);
    // Heights from the pass's reads (`heights`), never the rows' offsetHeight: this runs after the
    // pass's first animation started, where each read forced a style pass (R2; cmux#48689 read
    // 46,640 of them in one turn's end, turn-end-fold-restyle.browser.test.ts).
    const clearFraction = (index: number) => {
      if (!progressAt) return 1;
      const top = tops[index]!;
      const bottom = top + heights[index]!;
      let last = -1;
      for (let step = 0; step <= 200; step++) {
        const progress = progressAt(step / 200);
        const overlaps = nodes.some((other, k) => {
          if (k === index || drift[k] === 0 || arrives(other, k)) return false;
          const drawn = tops[k]! + drift[k]! * (1 - progress);
          return Math.min(bottom, drawn + heights[k]!) - Math.max(top, drawn) > 0.5;
        });
        if (overlaps) last = step;
      }
      return Math.min(1, (last + 1) / 200);
    };
    /// How far into the move this pass runs, and the latest hold it gives a row that arrives.
    const elapsed = Math.max(0, -toMove());
    let holds = 0;
    /// `viscous`: each moving row's delay, a 120 Hz frame per row between it and the fold's seam (the
    /// folded line), the nearest first; the spread stays inside the quick step.
    const seam = line ?? tops[0] ?? 0;
    const viscousDelay = new Map<HTMLElement, number>();
    if (look === "viscous") {
      const movers = nodes
        .map((node, index) => ({ node, index }))
        .filter(({ index }) => Math.abs(drift[index]!) >= 0.5)
        .sort((a, b) => Math.abs(tops[a.index]! - seam) - Math.abs(tops[b.index]! - seam));
      const step = Math.min(FRAME_MS, MOTION_MS.quick / Math.max(1, movers.length - 1));
      movers.forEach(({ node }, rank) => viscousDelay.set(node, rank * step));
      holds = Math.max(holds, ...viscousDelay.values());
    }
    /// `swap`'s snapshot places, written once every row is read (one layout per pass).
    const snapshotPlaces: [HTMLElement, number][] = [];
    nodes.forEach((node, index) => {
      const before = was.get(node.dataset.rowId!);
      // Its path, for the copies under or over it (`coverClip`), with the clip it starts under (below).
      const path = boxes.length ? { from: tops[index]!, to: tops[index]!, ...boxes[index]! } : undefined;
      if (path) paths.push(path);
      if (arrives(node, index)) {
        // A row first mounted in the settle snapshot has its final layout top, so it is placed there
        // at once. The kept rows above it still slide into their places, and drawn over them it
        // doubled its text (Leo, 2026-11-18: "doubled up looking ass text"; agent-pane-stream-row-
        // overlap). Carrying it with them flew it in from hundreds of pixels away. So it holds at no
        // ink until the move has landed (the move's delay, then its length), and fades in there. This
        // covers a renamed streaming reply, a reply outside the warm window, and rows that arrive with
        // the next turn.
        // The hold is read again on every pass (cmux#48689 F1): a row above measured shorter, or the
        // view scrolled, and a kept row now crosses a box it did not at the first pass. The reply then
        // goes back to no ink until that row has passed. A hold that ends before this pass (nothing
        // crosses any more) starts the fade now, and a fade already running is left to run.
        const clear = ms * clearFraction(index);
        const last = moving.get(node);
        // Nothing crosses a row that plays its own entrance: that entrance is its only fade.
        if (clear === 0 && !last && node.matches(".acpmux-row--enter, .acpmux-row--message-enter")) {
          entering = true;
          return;
        }
        const running = !grew && last?.fades && (last.hold ?? 0) <= elapsed;
        const hold = clear > elapsed ? clear : running ? (last.hold ?? 0) : elapsed;
        holds = Math.max(holds, hold);
        const from = hold > elapsed ? 0 : (starts.get(node)?.opacity ?? 0);
        const recap = node.classList.contains(`acpmux-${NEXT_STEP}`) ? recapLook : "hold";
        // Its band is its place: it is already laid out there, holding at no ink and fading in. Out of
        // the reader's view `restart` draws it at full ink instead, which is where that fade ends.
        restart(
          node,
          moving,
          { from: tops[index]!, to: tops[index]!, height: heights[index]! },
          { delta: 0, fades: true, animations: [], hold },
          () => [recapEntrance(recap, from, node.offsetHeight)],
          { delay: hold, fill: "backwards", ...(recap !== "hold" && { easing: MOTION_EASE_OUT }) },
        );
        return;
      }
      if (!before) {
        // It holds at no ink while a kept row sliding into place still crosses its box, as a row that
        // arrives does (above): the "Worked for" of the work after a steer lands under the steer, and
        // the steer slides up out of that box as the rows above close the fold. Fading from the
        // move's start, the line's ink drew inside the steer's box over the first frames (11.5 px
        // in steer-fold-boundary-browser.test.ts's turn end; Leo, 2026-11-22, ask-6cbe3d05b7: the
        // fold swept rows up past his steer). Read again each pass, as the arriving row's hold is.
        const clear = ms * clearFraction(index);
        const last = moving.get(node);
        // Its own entrance is enough only when no kept row crosses it. Rows inserted between
        // retained rows take this path too, so they need the same clearance as tail arrivals.
        if (clear === 0 && !last && node.matches(".acpmux-row--enter, .acpmux-row--message-enter")) {
          entering = true;
          return;
        }
        const running = !grew && last?.fades && (last.hold ?? 0) <= elapsed;
        const hold = clear > elapsed ? clear : running ? (last.hold ?? 0) : 0;
        holds = Math.max(holds, hold);
        const from = hold > elapsed ? 0 : (starts.get(node)?.opacity ?? 0);
        // Its band is where it lands. Out of view it is drawn there at full ink instead: a fade no one
        // sees is a half-state to whoever scrolls to it (the closed "Worked for" of a turn that ended
        // above the view).
        restart(
          node,
          moving,
          { from: tops[index]!, to: tops[index]!, height: heights[index]! },
          { delta: 0, fades: true, animations: [], ...(hold > 0 && { hold }) },
          () => [[{ opacity: from }, { opacity: 1 }]],
          hold > 0 ? { delay: hold, fill: "backwards" } : {},
        );
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
      const height = heights[index]!;
      let clip = shown === undefined ? 0 : Math.max(0, from + height - shown);
      for (const copyTop of copyStarts) if (copyTop > from) clip = Math.max(clip, from + height - copyTop);
      // A row the swap's render grew (the reply's last lines, shown in the commit that
      // ends its stream: revealedMarkdownModel.ts) starts as tall as it drew and opens to its full height on the fold's clock. Grown
      // at once in the swap's frame, the lines showed a frame of motion of their own before the fold
      // began, a second motion (cmux#50299).
      // Read as the capture read it (a box, not the rounded offsetHeight), so a row that did not grow clips nothing.
      if (!starts.has(node) && !before.replacesHeader && before.height !== undefined)
        clip = Math.max(clip, node.getBoundingClientRect().height - before.height);
      // An offscreen start skips the move below and draws this row at rest. Its ghost cover must
      // use that actual place too: the captured path may be wholly above the view while the row
      // now covers a visible copy (CMUX-896, reply-settle-frames F5). Keep an existing move's path.
      if (path && (moving.has(node) || startsInView(node, from, height)))
        Object.assign(path, { from, clip: clip >= 0.5 ? clip : undefined });
      // Work stays below the header as it moves into the closed turn's place. Both share this
      // clock, so keeping their start and end ordered keeps every frame ordered too.
      if (clip >= 0.5 || node.classList.contains(`acpmux-${WORKED}`))
        covers.push({ top: from, bottom: tops[index]! + height });
      // Whole-box above everything the swap changed, and the fold is carrying it up: played, not
      // declared (`risen`), so the judge reads it as the shift it is. A row that came down with the
      // work folding away, or one inside the turn, is the fold's own motion and stays declared.
      if (Number.isFinite(changedTop) && from + height <= changedTop + 0.5 && delta > 0.5) risen.add(node);
      else risen.delete(node);
      if (Math.abs(delta) < 0.5 && clip < 0.5 && !moving.has(node)) return;
      /// The band of this move, for `restart`'s gate: the start box, the landing box, and what the row
      /// sweeps between them. The row's box stayed in `covers` and in `path` above whether it animates
      /// or not, so every row and copy in the view is clipped against the same boxes it reads today --
      /// the rule is which rows animate, never which rows exist.
      const band = { from, to: tops[index]!, height };
      // `dissolve`: the row holds where it was while its ink goes, and comes back in at its place. Its two
      // halves are timed in the keyframes, so the animation runs on the straight line.
      const subagent = isSubagentNode(node) ? subagentLook : "slide";
      const snapshot = snapshots.get(node.dataset.rowId!);
      // `swap`: the subagent block is drawn where it lands at once, fading in there over the move as its
      // snapshot, held where it was drawn, fades out.
      if (subagent === "swap" && snapshot && Math.abs(delta) >= 0.5 && clip < 0.5) {
        const order = [...snapshots.values()].indexOf(snapshot);
        // Where the slide starts the row (`from`): its drawn top, carried with the rows mounted above since.
        snapshotPlaces.push([snapshot, from - snapshotTops[order]!]);
        restart(node, moving, band, { delta, fades: true, animations: [] }, () => [[{ opacity: 0 }, { opacity: 1 }]], {
          easing: MOTION_EASE_OUT,
        });
        // The snapshot is drawn where the row started and fades there, so the move's band is its band too.
        restart(
          snapshot,
          moving,
          band,
          { delta, fades: true, animations: [] },
          () => [[{ opacity: 1 }, { opacity: 0 }]],
          { easing: EASE_IN, fill: "both" },
        );
        return;
      }
      if ((look === "dissolve" || subagent === "dip") && Math.abs(delta) >= 0.5 && clip < 0.5) {
        restart(
          node,
          moving,
          band,
          { delta, fades: false, animations: [], clip },
          () => [
            [
              { translate: `0 ${delta}px`, opacity: 1, easing: EXIT_EASING },
              { offset: 0.35, translate: `0 ${delta}px`, opacity: 0 },
              { offset: 0.35, translate: "0 0", opacity: 0, easing },
              { translate: "0 0", opacity: 1 },
            ],
          ],
          { easing: "linear" },
        );
        return;
      }
      const lag = viscousDelay.get(node) ?? 0;
      restart(
        node,
        moving,
        band,
        { delta, fades: false, animations: [], clip, ...(lag > 0 && { hold: lag }) },
        () => [
          [{ translate: `0 ${delta}px` }, { translate: "0 0" }],
          // The clip as read, not rounded up: a whole pixel more hid part of a line the reader had seen,
          // a step of up to 1 px on the fold's first frame (fade seed 74 on cmux#50751).
          ...(clip >= 0.5 ? [[{ clipPath: clipBottom(clip) }, { clipPath: clipBottom(0) }]] : []),
        ],
        lag > 0 ? { delay: lag, fill: "backwards" } : {},
      );
    });
    for (const [snapshot, offset] of snapshotPlaces) snapshot.style.translate = `0 ${offset}px`;
    // A snapshot whose row did not move (or is not drawn now) pictures nothing that changes: it goes.
    for (const [id, snapshot] of snapshots) {
      const row = nodes.find((node) => node.dataset.rowId === id);
      if (row && moving.has(row)) continue;
      for (const animation of moving.get(snapshot)?.animations ?? []) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      moving.delete(snapshot);
      snapshot.remove();
      fold.copies.delete(snapshot);
      snapshots.delete(id);
    }
    if (Math.abs(holds - tail) >= 1) {
      tail = holds;
      if (fold.timer !== undefined) arm();
    }
    const placedById = new Map(nodes.map((node, index) => [node.dataset.rowId!, { node, index }]));
    type Boundary = { row: Drawn; node: HTMLElement; index: number };
    const boundaries = new Map<HTMLElement, { above?: Boundary; below?: Boundary }>();
    for (const step of [1, -1]) {
      let boundary: Boundary | undefined;
      for (let at = step === 1 ? 0 : capture.rows.length - 1; at >= 0 && at < capture.rows.length; at += step) {
        const row = capture.rows[at]!;
        if (row.copy) {
          const pair = boundaries.get(row.copy) ?? {};
          if (step === 1) pair.above = boundary;
          else pair.below = boundary;
          boundaries.set(row.copy, pair);
        } else {
          const placed = placedById.get(row.id);
          if (placed) boundary = { row, ...placed };
        }
      }
    }
    copies.forEach((copy, order) => {
      const from = copyStarts[order]!;
      const at = from - copyTops[order]!;
      let end = (look === "tuck" || look === "cascade") && line !== undefined ? line - copyTops[order]! : at;
      // `sheet`, `water`: the copy moves as the row under it does (else the row over it), so the work and
      // the answer travel as one surface and the rows closing over it crop it.
      if (ridesSheet(look)) {
        const { above: over, below: under } = boundaries.get(copy) ?? {};
        const rider = under ?? over;
        if (rider) end = at + tops[rider.index]! - startTop(rider.node, rider.row.top);
      }
      // Under a clipped row (above): it ends no higher than that row's bottom at rest, so with the clip
      // opening on the same clock, the row's drawn bottom never passes the copy's drawn top. The move
      // is linear in the fold's progress on both, so where it holds at the first and last frame it
      // holds on every frame between.
      for (const cover of covers) if (cover.top < from) end = Math.max(end, cover.bottom - copyTops[order]!);
      // The work fades only between the surviving rows that surrounded it. Those rows can
      // move over its former place, so crop the copy on their shared clock rather than drawing
      // its text through the header or the final answer.
      const { above, below } = boundaries.get(copy) ?? {};
      const height = copyHeights[order]!;
      const topFrom = above
        ? Math.max(0, startTop(above.node, above.row.top) + (above.row.height ?? heights[above.index]!) - from)
        : 0;
      const topTo = above ? Math.max(0, tops[above.index]! + heights[above.index]! - (copyTops[order]! + end)) : 0;
      const bottomFrom = Math.max(
        goneByCopy.get(copy)!.clip ?? 0,
        below ? from + height - startTop(below.node, below.row.top) : 0,
      );
      const bottomTo = below ? Math.max(0, copyTops[order]! + end + height - tops[below.index]!) : 0;
      const cropFrom = `inset(${topFrom}px -4096px ${Math.max(0, bottomFrom)}px -4096px)`;
      const cropTo = `inset(${topTo}px -4096px ${bottomTo}px -4096px)`;
      const crop = [topFrom, topTo, bottomFrom, bottomTo].some((value) => value >= 0.5)
        ? `${cropFrom}|${cropTo}`
        : undefined;
      const box = boxes[nodes.length + order]!;
      const cover = coverClip({ from, to: copyTops[order]! + end, ...box }, paths, clippedBottomOf(copy));
      const covered = cover ? JSON.stringify(cover) : undefined;
      // A copy drawn outside the view where its animation would start takes its final state at once: no ink,
      // no exit fade and no move. The row it pictures is gone from the new frame, so there is no other
      // place it could be drawn -- but neither place is in the view, and the "drawn in at least one
      // place" rule is about what the reader sees, so nothing of his is dropped.
      // The element stays in the thread, at no ink, rather than being removed: it is still in
      // `copyStarts`, `boundaries` and `covers`, so every row and copy that IS in view is clipped
      // against exactly the box set it reads today. Removing it would change a visible row's clip on
      // the next pass, which is the edge's-run problem in another shape.
      // A copy already moving is gated the same way, and for the same reason `restart` gates a row that
      // is: the test comes before the cancel below, so what is running is left to run out. Its exit
      // ends at no ink and its move at its landing place, which is the final state this branch writes
      // anyway, so a copy carried out of the view finishes there quietly instead of starting again.
      // Latched, unlike a row: a row out of sight is drawn where it belongs, so a later pass may still
      // animate what is left of its path, but a copy's final state is gone -- a reader who scrolls to
      // its place must find the swap there, not a row the turn took away fading in from full ink.
      /// `from` is remembered (`startTop`), so a scroll since the capture leaves it stale; `drawnTop`
      /// is where this copy is drawn in this pass. Either box outside the view is a start the reader
      /// cannot see (`restart` says it at length).
      const copyDrawn = drawnTop.get(copy);
      const copySeen = (copyDrawn === undefined || bandSeen(copyDrawn, height)) && startSeen(from, height);
      if (unseen.has(copy) || !copySeen) {
        unseen.add(copy);
        copy.style.opacity = "0";
        return;
      }
      const last = copyMoves.get(copy);
      if (
        !grew &&
        last &&
        Math.abs(last.delta - at) < 0.5 &&
        Math.abs((last.end ?? at) - end) < 0.5 &&
        last.covered === covered &&
        last.crop === crop
      )
        return;
      for (const animation of last?.animations ?? []) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      // Held at its start until the move, so a copy that has faded never shows full again.
      // `cascade`: the first row first, each a step after the one over it, inside the first half of the move.
      const foldDelay = look === "cascade" ? (ms * 0.5 * order) / Math.max(1, copies.length) : 0;
      const timing: KeyframeAnimationOptions = { fill: "both", ...(foldDelay > 0 && { delay: foldDelay }) };
      // The last row first, each a step after the one under it, inside the exit lead.
      const step = look === "stagger" ? exitMs / Math.max(2, copies.length * 2) : 0;
      // The copy's text is gone when the exit lead ends, before it or anything over it moves: faded on
      // the move's clock (by 60% of it, #41078), its text still travelled, faint, while the rows
      // slid over its place (agent-pane-stream-row-overlap: 5.5 px under the reply at 94%).
      const faded = exit(copy, exitFrom + foldDelay + (copies.length - 1 - order) * step);
      const motion = play(
        copy,
        [
          { translate: `0 ${at}px`, ...(crop && { clipPath: cropFrom }) },
          { translate: `0 ${end}px`, ...(crop && { clipPath: cropTo }) },
        ],
        timing,
      );
      // The clip on the rows' own clock (a stagger's delay is the copy's fade alone), held at its end.
      const clipped = cover ? play(copy, cover, { fill: "both" }) : undefined;
      copyMoves.set(copy, {
        delta: at,
        fades: true,
        animations: clipped ? [faded, motion, clipped] : [faded, motion],
        end,
        covered,
        crop,
      });
    });
    /// `morph`: one card from the line over the folded rows to the row under them. It fades in as the copies
    /// go and shrinks, on the rows' clock, to the gap they close to, fading as it lands: the band the
    /// copies leave is never blank. It draws under every row (first in the thread).
    const playCard = () => {
      const first = gone[0]?.copy;
      const above = first ? boundaries.get(first)?.above : undefined;
      // The lowest row that stays with folded rows over it: the live line, the turn's last row, has none.
      const below = gone
        .map((row) => boundaries.get(row.copy!)?.below)
        .filter((boundary) => boundary !== undefined)
        .at(-1);
      if (!first || !below || nodes.length === 0) return;
      const parentTop = tops[0]! - nodes[0]!.offsetTop;
      // The line over the work was out of the window when the turn ended (a long turn, read at its
      // bottom): the card starts at the first folded row's top and lands under the folded line.
      const header = nodes.findIndex((node) => node.classList.contains(`acpmux-${WORKED}`));
      const fromTop = above
        ? startTop(above.node, above.row.top) + (above.row.height ?? above.node.offsetHeight)
        : startTop(first, gone[0]!.top);
      const toTop = above
        ? tops[above.index]! + above.node.offsetHeight
        : header >= 0
          ? tops[header]! + nodes[header]!.offsetHeight
          : tops[below.index]!;
      const fromBottom = startTop(below.node, below.row.top);
      const toBottom = tops[below.index]!;
      const top = Math.min(fromTop, toTop);
      const bottom = Math.max(fromBottom, toBottom);
      if (!(bottom - top > 1)) return;
      const key = [fromTop, toTop, fromBottom, toBottom].map((value) => Math.round(value)).join(" ");
      if (card && card.key === key && !grew) return;
      if (!card) {
        const element = thread.ownerDocument.createElement("div");
        element.className = TURN_END_CARD;
        element.setAttribute("aria-hidden", "true");
        const fill = thread.ownerDocument.createElement("div");
        element.append(fill);
        thread.insertBefore(element, thread.firstElementChild);
        fold.copies.add(element);
        card = { element, key, animations: [] };
        const comesIn = fill.animate([{ opacity: 0 }, { opacity: 1 }], {
          duration: Math.max(1, lead || exitMs),
          easing: EXIT_EASING,
          fill: "both",
        });
        fold.animations.add(comesIn);
      }
      for (const animation of card.animations) {
        animation.cancel();
        fold.animations.delete(animation);
      }
      card.key = key;
      Object.assign(card.element.style, { top: `${top - parentTop}px`, height: `${bottom - top}px` });
      const inset = (from: number, to: number) => `inset(${from - top}px 0 ${bottom - to}px 0 round 10px)`;
      card.animations = [
        play(
          card.element,
          [
            { clipPath: inset(fromTop, fromBottom), opacity: 1 },
            { offset: 0.6, opacity: 1 },
            { clipPath: inset(toTop, toBottom), opacity: 0 },
          ],
          { fill: "both" },
        ),
      ];
    };
    if (look === "morph") playCard();
    nodes.forEach((node, index) => laid.set(node, tops[index]!));
    copies.forEach((copy, order) => laid.set(copy, copyTops[order]!));
  };
  pass();
  if (fold.animations.size === 0 && !entering) {
    settleTurnEnd(thread, fold);
    return undefined;
  }
  thread.setAttribute(TURN_END_ATTR, look);
  // Each time the rows are placed again (a row mounts or leaves, a row's offset changes) or the
  // view's offset moves (the bottom kept pinned), the next pass reads them again, at once: a pass
  // put off to the next animation frame left a row placed after that frame's callbacks one frame
  // off its path (agent-pane-stream-jitter, WebKit, a queued prompt sent as the turn ends: the reply
  // drawn 35 px back up). A mutation batch already comes once per microtask checkpoint and a scroll
  // once per frame; `sameFramePasses` counts the passes that still share a frame.
  let lastFrame: number | null | undefined;
  const passAgain = () => {
    const frame = typeof timeline?.currentTime === "number" ? timeline.currentTime : null;
    if (frame !== null && frame === lastFrame) turnEndFoldPerf.sameFramePasses += 1;
    lastFrame = frame;
    pass();
  };
  // The observer watches the thread's own children (a row mounts or leaves) and each row's own
  // `style` and `aria-posinset` (its offset), never the rows' subtrees: a write deep in a row (a
  // roll-out's width, a reply's text) never wakes it (chat-render-pipeline R9). A row that mounts
  // during the fold is watched from its mount on. All of it stops with the fold.
  const watched = new WeakSet<Element>();
  const watchRows = (observer: MutationObserver) => {
    for (const row of mounted(thread)) {
      if (watched.has(row)) continue;
      watched.add(row);
      observer.observe(row, { attributes: true, attributeFilter: ["style", "aria-posinset"] });
    }
  };
  const observer = View?.MutationObserver
    ? new View.MutationObserver((records, self) => {
        turnEndFoldPerf.mutationEvents += 1;
        const placed = (record: MutationRecord) =>
          record.type === "childList"
            ? record.target === thread
            : record.target.parentNode === thread && (record.target as Element).hasAttribute("data-row-id");
        if (records.some((record) => record.type === "childList")) watchRows(self);
        if (records.some(placed)) passAgain();
      })
    : undefined;
  if (observer) {
    observer.observe(thread, { childList: true });
    watchRows(observer);
  }
  const onScroll = () => {
    turnEndFoldPerf.scrollEvents += 1;
    passAgain();
  };
  scroller?.addEventListener("scroll", onScroll, { passive: true });
  const unscroll = endOnReaderScroll(thread, scroller, fold);
  fold.stop = () => {
    if (firstFrame !== undefined) View?.cancelAnimationFrame(firstFrame);
    observer?.disconnect();
    scroller?.removeEventListener("scroll", onScroll);
    unscroll();
  };
  // A hidden page suspends its animations: nothing of the fold outlasts its length.
  arm(lead);
  return fold;
}
