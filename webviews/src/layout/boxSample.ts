// Sampling the boxes a person reads, one frame at a time: the gallery's box shift (gallery/shift.ts) and
// the undeclared-move audit (motionAudit.ts) read the same samples. Moved here from gallery/shift.ts so a
// dev build's audit does not reach into the gallery.
import { surfaceById, surfaceOf } from "./motionContract";

export type Box = { x: number; y: number; width: number; height: number };

/**
 * One tracked box in one frame. `after` is true when it follows the step's target in document order;
 * `before` when it precedes a target whose row is opening at the bottom of its transcript (`BOTTOM_FOLD`).
 */
export type BoxSample = {
  box: Box;
  label: string;
  /** Its surface in the layout-motion contract (schemas/layout-motion/contract.json). */
  surface?: string;
  targeted?: boolean;
  after?: boolean;
  before?: boolean;
  /** A keyframe animation on it or an ancestor is running or about to start: its moves are that
   *  animation's, not a shift, and it has not rested. */
  animating?: boolean;
  /** A transcript row (`data-row-id`): the follow judge (gallery/followJudge.ts) wants every one in view to
   *  move by the same translation. */
  row?: boolean;
  /** The composer or its bar: the follow judge wants it never to move. */
  composer?: boolean;
  /** The part of `box` that paints, when less than all of it (`shownBox`): the box less its own
   *  `clip-path: inset()`, and for a box that is not a transcript row, less what its scrolling or
   *  clipping ancestors cut off. The follow judge reads it; the box score reads `box`. */
  shown?: Box;
  /** The turn's end fold (turnEndFold.ts) is sliding it: a script animation (`element.animate`, not
   *  a CSS animation or transition) moves it, or an ancestor, inside the thread while
   *  `data-turn-end-folding` is set. The fold's own motion, so the follow judge does not judge it;
   *  the box score does not read it. */
  folding?: boolean;
  /** The running turn's live line while pinnedLiveLine.ts holds it still against the follow chase
   *  (`data-pin-live` on its thread; the line is the thread's last row): the follow judge wants it to
   *  hold or follow, and does not judge its gap to the reply the chase brings home over it. */
  pinned?: boolean;
  /** The id of the nearest tracked box that holds this one (an option's listbox, a menu item's
   *  menu), for a box that is not a transcript row: the follow judge lets it keep its place in it. */
  within?: number;
  /** The laid-out box of the nearest ancestor that clips its overflow (the scroller a listbox sits
   *  in), for a box that is not a transcript row: the follow judge lets it keep its place in it. */
  port?: Box;
};
export type BoxFrame = Map<number, BoxSample>;

/** The transcript row that is opening or closing at the very bottom, so the text above it rises or
 *  falls (App.tsx `beginBottomStackFold`, `data-bottom-stack-fold`, set for every bottom stack), and
 *  the running tray placed after the latest message (`.acpmux-transcript-after-latest`, the
 *  subagent tray's after-latest placement): it is always the transcript's end, so opening it while
 *  the view follows the end pushes the text above up by what opened, by design (SubagentTray.gallery
 *  `expand-after-latest`); away from the end it opens below the view and nothing above it moves. */
export const BOTTOM_FOLD = "[data-bottom-stack-fold], .acpmux-transcript-after-latest";

/** The running tray over the composer (`.acpmux-running-tray` in the dock). What it opens moves no
 *  row, save over the running turn's live line: while that line is the transcript's last row, the
 *  tray lies over at most half the line's rest gap and the rows rise with it for the rest, so the
 *  line stays in sight (VirtualTranscript `trayBase`; Leo, 2026-11-04: "why does it not display
 *  Thinking or anything here???"). Only then is it a fold at the bottom; with any other last row a
 *  row that rises is still a shift. */
const RUNNING_TRAY = ".acpmux-running-tray";
const LIVE_LINE_ROW = "acpmux-row--below";

/** The fold at the very bottom that `target` opens or closes, if it is one (`BOTTOM_FOLD`, or the
 *  running tray over the live line). */
export function bottomFoldOf(target: Element): Element | null {
  const fold = target.closest(BOTTOM_FOLD);
  if (fold) return fold;
  const tray = target.closest(RUNNING_TRAY);
  if (!tray) return null;
  const rows = target.ownerDocument.querySelectorAll(".acpmux-row");
  return rows[rows.length - 1]?.classList.contains(LIVE_LINE_ROW) ? tray : null;
}

/**
 * The rows a person reads: transcript rows, the composer and its bar, menus and their items, list,
 * tree and grid rows, and anything an entry marks `data-gallery-track`. Kept to a bounded set so a
 * per-frame sample stays cheap.
 */
export const TRACK_SELECTOR = [
  "[data-row-id]",
  "[data-gallery-track]",
  ".acpmux-composer-box",
  ".acpmux-composer-bar",
  "[role='menu']",
  "[role='listbox']",
  "[role='menuitem']",
  "[role='menuitemradio']",
  "[role='menuitemcheckbox']",
  "[role='option']",
  "[role='row']",
  "[role='treeitem']",
  "[role='tab']",
].join(",");

/** A step's target, or the elements it and the play clicked (`clicked` in playRunner.ts). */
export type StepTargets = Element | readonly Element[] | null | undefined;

export const targetList = (target: StepTargets): readonly Element[] =>
  !target ? [] : "nodeType" in target ? [target as Element] : (target as readonly Element[]);

const ids = new WeakMap<Element, number>();
let nextId = 1;
const idOf = (element: Element) => {
  let id = ids.get(element);
  if (id === undefined) ids.set(element, (id = nextId++));
  return id;
};

function labelOf(element: Element): string {
  const row = element.getAttribute("data-row-id");
  const role = element.getAttribute("role");
  const className = typeof element.className === "string" ? element.className.split(" ")[0] : "";
  return `${element.tagName.toLowerCase()}${className ? `.${className}` : ""}${row ? `[row ${row}]` : role ? `[${role}]` : ""}`;
}

const surfaces = new WeakMap<Element, string>();
const surfaceIdOf = (element: Element) => {
  let id = surfaces.get(element);
  if (id === undefined) surfaces.set(element, (id = surfaceOf(element).id));
  return id;
};

/** The tracked boxes now, with each one's relation to `target` (the step's targets: any of them). */
export function sampleBoxes(doc: Document, target: StepTargets, extra: Element[] = []): BoxFrame {
  const frame: BoxFrame = new Map();
  const view = doc.defaultView;
  const width = view?.innerWidth ?? 0;
  const height = view?.innerHeight ?? 0;
  // The row opening at the very bottom moves as one: what it holds (a batch's message rows) rises
  // with its toggle and the text above, so it is the target's as much as the toggle's line is.
  const targets = targetList(target).map((each) => ({ each, folding: bottomFoldOf(each) }));
  const moving = animatedElements(doc);
  const folding = foldMovedElements(doc);
  const pinnedLines = pinnedLiveLines(doc);
  const tracked = new Set([...doc.querySelectorAll(TRACK_SELECTOR), ...extra]);
  const clips = new Map<Element, Box | null>();
  for (const element of tracked) {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= height || rect.left >= width) continue;
    const row = element.hasAttribute("data-row-id");
    const box = { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
    const { shown, port } = view ? shownBox(element, box, view, !row, clips) : { shown: box, port: undefined };
    const targeted = targets.some(
      ({ each, folding }) =>
        element === each || element.contains(each) || each.contains(element) || !!folding?.contains(element),
    );
    let after = false;
    let before = false;
    if (!targeted)
      for (const { each, folding } of targets) {
        const position = each.compareDocumentPosition(element);
        after ||= (position & 4) !== 0; // 4: DOCUMENT_POSITION_FOLLOWING (no global Node in tests)
        before ||= !!folding && (position & 2) !== 0; // 2: DOCUMENT_POSITION_PRECEDING
      }
    const sample: BoxSample = {
      box,
      label: labelOf(element),
      surface: surfaceIdOf(element),
      targeted,
      after,
      before,
      animating: moving.size > 0 && inMotion(element, moving),
      row,
      composer: element.matches(".acpmux-composer-box, .acpmux-composer-bar"),
    };
    if (!sameBox(shown, box)) sample.shown = shown;
    if (port) sample.port = port;
    if (folding.size > 0 && inMotion(element, folding)) sample.folding = true;
    if (pinnedLines.has(element)) sample.pinned = true;
    if (!row)
      for (let node = element.parentElement; node; node = node.parentElement)
        if (tracked.has(node)) {
          sample.within = idOf(node);
          break;
        }
    frame.set(idOf(element), sample);
  }
  return frame;
}

const sameBox = (a: Box, b: Box) =>
  Math.abs(a.x - b.x) < 0.01 &&
  Math.abs(a.y - b.y) < 0.01 &&
  Math.abs(a.width - b.width) < 0.01 &&
  Math.abs(a.height - b.height) < 0.01;

function intersect(a: Box, b: Box): Box {
  const x = Math.max(a.x, b.x);
  const y = Math.max(a.y, b.y);
  return {
    x,
    y,
    width: Math.max(0, Math.min(a.x + a.width, b.x + b.width) - x),
    height: Math.max(0, Math.min(a.y + a.height, b.y + b.height) - y),
  };
}

/** What a `clip-path: inset(...)` in px crops off `box` (its top, right, bottom and left, never
 *  less than 0: a negative inset crops nothing), or null for no clip or one this does not read. */
export function insetCrop(clipPath: string): [number, number, number, number] | null {
  const inset = /^inset\(([^)]*)\)/.exec(clipPath.trim());
  if (!inset) return null;
  const words = inset[1]!
    .split(/\s+round\s+/)[0]!
    .trim()
    .split(/\s+/);
  if (!words.length || words.length > 4) return null;
  const sides: number[] = [];
  for (const word of words) {
    if (!/^-?[\d.]+(px)?$/.test(word)) return null;
    sides.push(Math.max(0, Number.parseFloat(word)));
  }
  const [top, right = top, bottom = top, left = right] = sides as [number, ...number[]];
  return [top, right, bottom, left];
}

/**
 * The part of `box` that paints: less its own `clip-path: inset()` (the running turn's pinned live
 * line clips the reply over it at the line's drawn top, pinnedLiveLine.ts), and with `ancestors`,
 * less what each ancestor that clips its overflow (a scroller, a popup) cuts off. Transcript rows
 * skip the ancestors: the transcript's scroller cuts the rows the follow takes past its edge, and a
 * row is judged by where it is drawn, cut or not. Each ancestor's clip is read once a sample (`clips`).
 */
export function shownBox(
  element: Element,
  box: Box,
  view: Window,
  ancestors: boolean,
  clips: Map<Element, Box | null>,
): { shown: Box; port?: Box } {
  let shown = box;
  let port: Box | undefined;
  const crop = insetCrop(view.getComputedStyle(element).clipPath ?? "");
  if (crop) {
    const [top, right, bottom, left] = crop;
    shown = {
      x: box.x + left,
      y: box.y + top,
      width: Math.max(0, box.width - left - right),
      height: Math.max(0, box.height - top - bottom),
    };
  }
  if (!ancestors) return { shown };
  for (let node = element.parentElement; node && node !== element.ownerDocument.body; node = node.parentElement) {
    let clip = clips.get(node);
    if (clip === undefined) {
      const style = view.getComputedStyle(node);
      const clipping = (value: string) => value !== "" && value !== "visible";
      if ([style.overflow, style.overflowX, style.overflowY].some((value) => clipping(value ?? ""))) {
        const rect = node.getBoundingClientRect();
        clip = { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
      } else clip = null;
      clips.set(node, clip);
    }
    if (clip) {
      shown = intersect(shown, clip);
      port ??= clip;
    }
  }
  return port ? { shown, port } : { shown };
}

/** The thread a pinned live line holds still in (pinnedLiveLine.ts `PIN_LIVE_ATTR`). */
export const PIN_LIVE = "[data-pin-live]";
/** The live lines held still now (`pinned`): each pinned thread's last row (pinnedLiveLine.ts pins
 *  the line only while it is the thread's last row). */
function pinnedLiveLines(doc: Document): Set<Element> {
  const lines = new Set<Element>();
  for (const thread of doc.querySelectorAll(PIN_LIVE)) {
    const rows = thread.querySelectorAll(":scope > [data-row-id]");
    const last = rows[rows.length - 1];
    if (last) lines.add(last);
  }
  return lines;
}

/** The elements the turn's end fold is moving (`folding`): targets of a running script animation
 *  (`element.animate`: neither a CSSAnimation nor a CSSTransition) that moves a box, inside a thread
 *  that has `data-turn-end-folding`. */
export const TURN_END_FOLDING = "[data-turn-end-folding]";
function foldMovedElements(doc: Document): Set<Element> {
  const moved = new Set<Element>();
  if (!doc.querySelector(TURN_END_FOLDING)) return moved;
  for (const animation of doc.getAnimations?.() ?? []) {
    if (animation.playState === "finished" || animation.playState === "idle") continue;
    if ("animationName" in animation || "transitionProperty" in animation) continue;
    const effect = animation.effect as KeyframeEffect | null;
    if (!effect?.target?.closest(TURN_END_FOLDING)) continue;
    const moves = effect.getKeyframes().some((frame) => Object.keys(frame).some((key) => MOVING_PROPERTIES.has(key)));
    if (moves) moved.add(effect.target);
  }
  return moved;
}

/** Keyframe properties that move a box without a layout change. */
const MOVING_PROPERTIES = new Set(["transform", "translate", "scale", "rotate"]);

/** The elements a keyframe animation (a CSSAnimation, not a transition, which can carry a real
 *  shift) is moving, running or waiting to start: an entrance rise. A shimmer or fade moves nothing
 *  and leaves its box judged as before. */
function animatedElements(doc: Document): Set<Element> {
  const moving = new Set<Element>();
  for (const animation of doc.getAnimations?.() ?? []) {
    if (animation.playState === "finished" || animation.playState === "idle") continue;
    if (!("animationName" in animation)) continue;
    const effect = animation.effect as KeyframeEffect | null;
    if (!effect?.target) continue;
    const moves = effect.getKeyframes().some((frame) => Object.keys(frame).some((key) => MOVING_PROPERTIES.has(key)));
    if (moves) moving.add(effect.target);
  }
  return moving;
}

function inMotion(element: Element, moving: Set<Element>): boolean {
  for (let node: Element | null = element; node; node = node.parentElement) if (moving.has(node)) return true;
  return false;
}

/** Chat media the contract sizes from its record: sampled too, so an image that reshapes is caught. */
export const MEDIA_SELECTOR: string = surfaceById("chat-media")!.selector!;
