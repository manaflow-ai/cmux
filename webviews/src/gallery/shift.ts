// Box shift: layout shift measured from element boxes, frame by frame (Leo, 2026-11-01: "how about
// like the apparatuses for improving ui verification? let's examine what we can do better for our
// workflows"). The browser's own layout-shift entries (CLS) miss two things the stage must catch:
//   - a move that scrolling made: Chromium subtracts a scroller's scroll delta, so a bottom-pinned
//     transcript that scrolls its rows up when a tool call at the bottom expands reports no shift;
//   - motion outside Chromium: WebKit has no layout-shift entries at all.
// So the stage also samples the boxes of the rows a person reads (`TRACK_SELECTOR`, plus the entry's
// anchors) on every frame, in viewport coordinates, and scores their moves the way CLS does: per
// frame, the moved boxes' share of the viewport times the largest move's share of its longer side.
//
// What does not count, so a correct page scores 0:
//   - a box that has not yet held still for `REST_FRAMES` frames: an entrance animation, a row
//     still mounting. Once it rested, any later move counts (the composer gap that jumps on load).
//     A step starts on a settled page, so its first frame's boxes have rested (`restedAtStart`);
//   - the step's target, its ancestors and descendants (the tool row that expands), and while that
//     row opens at the very bottom (`BOTTOM_FOLD`), everything inside it: it rises as one;
//   - a box after the target in document order that moves straight down: the expansion pushes it;
//   - a box before the target that moves straight up while the target's transcript row opens at the
//     very bottom (`BOTTOM_FOLD`, `data-bottom-stack-fold`, set by the transcript for the length of
//     that fold): there the opening pushes the text above up by design (Leo, 2026-11-02: "YOU
//     EXPAND UP WHILE YOUR SCCROLL IS AT THE VERY BOTTOM AKA YOU ... PUSH THE TEXT UP VISUALLY
//     INSTEAD OF EXPANDING DOWN LIKE USUAL / JUST THAT CASE", #32644). Anywhere else a row rising is still a shift;
//   - a box's first move after a resize (`firstMoveFree`): the new width lays it out once; a second
//     move is the bounce a sidebar toggle must not have;
//   - moves under half a CSS px (layout rounding), and boxes outside the viewport.
// The pure scoring is here (unit tested); `startBoxTracker` samples the live page.

export type Box = { x: number; y: number; width: number; height: number };

/**
 * One tracked box in one frame. `after` is true when it follows the step's target in document order;
 * `before` when it precedes a target whose row is opening at the bottom of its transcript (`BOTTOM_FOLD`).
 */
export type BoxSample = { box: Box; label: string; targeted?: boolean; after?: boolean; before?: boolean };
export type BoxFrame = Map<number, BoxSample>;

export type BoxMove = { label: string; frame: number; dx: number; dy: number };
export type BoxShift = { score: number; moves: BoxMove[] };

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

/** Frames a box must hold still before its moves count. */
export const REST_FRAMES = 2;
/** Moves under this many CSS px are layout rounding. */
export const MOVE_SLACK = 0.5;
/** Moves listed in a report; the score still counts every one. */
const MAX_MOVES = 24;

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

const area = (box: Box) => Math.max(0, box.width) * Math.max(0, box.height);

function clip(box: Box, viewport: { width: number; height: number }): Box {
  const x = Math.max(0, box.x);
  const y = Math.max(0, box.y);
  return {
    x,
    y,
    width: Math.min(viewport.width, box.x + box.width) - x,
    height: Math.min(viewport.height, box.y + box.height) - y,
  };
}

function union(a: Box, b: Box): Box {
  const x = Math.min(a.x, b.x);
  const y = Math.min(a.y, b.y);
  return {
    x,
    y,
    width: Math.max(a.x + a.width, b.x + b.width) - x,
    height: Math.max(a.y + a.height, b.y + b.height) - y,
  };
}

/** The CLS-style score of a run of frames (see the header for what is exempt). */
export function scoreBoxFrames(
  frames: BoxFrame[],
  viewport: { width: number; height: number },
  options: { firstMoveFree?: boolean; restedAtStart?: boolean } = {},
): BoxShift {
  const still = new Map<number, number>();
  // A step starts on a page that has been still: its boxes have rested already.
  if (options.restedAtStart) for (const id of frames[0]?.keys() ?? []) still.set(id, REST_FRAMES);
  const freeUsed = new Set<number>();
  const moves: BoxMove[] = [];
  let score = 0;
  const longer = Math.max(viewport.width, viewport.height, 1);
  const viewportArea = Math.max(1, viewport.width * viewport.height);
  for (let index = 1; index < frames.length; index++) {
    const previous = frames[index - 1]!;
    const current = frames[index]!;
    let impact = 0;
    let distance = 0;
    for (const [id, now] of current) {
      const was = previous.get(id);
      if (!was) {
        still.delete(id);
        continue;
      }
      const dx = now.box.x - was.box.x;
      const dy = now.box.y - was.box.y;
      const moved = Math.abs(dx) > MOVE_SLACK || Math.abs(dy) > MOVE_SLACK;
      const rested = (still.get(id) ?? 0) >= REST_FRAMES;
      if (!moved) {
        still.set(id, (still.get(id) ?? 0) + 1);
        continue;
      }
      if (!rested) {
        still.set(id, 0);
        continue;
      }
      if (now.targeted) continue;
      if (now.after && dy > 0 && Math.abs(dx) <= MOVE_SLACK) continue;
      if (now.before && dy < 0 && Math.abs(dx) <= MOVE_SLACK) continue;
      if (options.firstMoveFree && !freeUsed.has(id)) {
        freeUsed.add(id);
        continue;
      }
      const seen = union(clip(was.box, viewport), clip(now.box, viewport));
      if (seen.width <= 0 || seen.height <= 0) continue;
      impact += area(seen) / viewportArea;
      distance = Math.max(distance, Math.max(Math.abs(dx), Math.abs(dy)) / longer);
      if (moves.length < MAX_MOVES)
        moves.push({ label: now.label, frame: index, dx: Math.round(dx * 10) / 10, dy: Math.round(dy * 10) / 10 });
    }
    score += Math.min(1, impact) * distance;
  }
  return { score: Math.round(score * 1e5) / 1e5, moves };
}

/** A source of a browser layout-shift entry (`LayoutShift.sources`): the node and its rects. */
export type LayoutShiftSource = {
  node?: Node | null;
  previousRect?: Pick<DOMRectReadOnly, "x" | "y" | "width" | "height">;
  currentRect?: Pick<DOMRectReadOnly, "x" | "y" | "width" | "height">;
};

/**
 * Whether a browser layout-shift entry is the step's own expansion, under the box rules above: every
 * source it names is the target, holds it or is inside it (or inside the row opening at the very
 * bottom, `BOTTOM_FOLD`), follows it and moved straight down, or, while that row opens at the very
 * bottom, precedes it and moved straight up. The browser has no idea which row the reader clicked, so
 * without this its CLS scores the push every fold makes by design: the rows under an opening tool
 * call sliding down with it. It scored only the slice of that push inside the step's settle window
 * (a few frames), so a fold whose curve moves more of its height in its first frames read as a
 * bigger shift, though every row went to the same place. With several targets (a step's own and
 * what the play clicked right before it), a source is exempt by any one of them.
 */
export function isExpansionShift(sources: readonly LayoutShiftSource[], target: StepTargets): boolean {
  const targets = targetList(target);
  if (!targets.length || !sources.length) return false;
  return sources.every((source) => targets.some((each) => expandedBy(source, each)));
}

/** A step's target, or the elements it and the play clicked (`clicked` in playRunner.ts). */
export type StepTargets = Element | readonly Element[] | null | undefined;

const targetList = (target: StepTargets): readonly Element[] =>
  !target ? [] : "nodeType" in target ? [target as Element] : (target as readonly Element[]);

function expandedBy({ node, previousRect: was, currentRect: now }: LayoutShiftSource, target: Element): boolean {
  const folding = bottomFoldOf(target);
  const element = node && node.nodeType === 1 ? (node as Element) : (node?.parentElement ?? null);
  if (!element || !was || !now) return false;
  if (element === target || element.contains(target) || target.contains(element) || folding?.contains(element))
    return true;
  const position = target.compareDocumentPosition(element);
  const following = (position & 4) !== 0; // DOCUMENT_POSITION_FOLLOWING
  // A box with no previous area (a clipped shimmer band in the line under the fold) only came
  // into view: no move of its own to judge, so it goes with the rows it sits in.
  if (was.width <= 0 || was.height <= 0) return following;
  // One with no current area left the view: the browser clips its new rect to nothing, so the rect
  // says nothing of where it went. A row after the target that an opening pushed past the
  // transcript's bottom (the running turn's live line under a digest that opens whole) is the
  // expansion's push; judge it by where its box is now, which must be straight below where it was.
  if (now.width <= 0 || now.height <= 0) {
    if (!following) return false;
    const live = element.getBoundingClientRect();
    return Math.abs(live.x - was.x) <= MOVE_SLACK && live.y > was.y + MOVE_SLACK;
  }
  const dx = now.x - was.x;
  const dy = now.y - was.y;
  if (Math.abs(dx) > MOVE_SLACK) return false;
  if (following) return dy > 0; // pushed down
  return !!folding && (position & 2) !== 0 && dy < 0; // DOCUMENT_POSITION_PRECEDING, at the bottom
}

// ---- Sampling the live page ----

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

/** The tracked boxes now, with each one's relation to `target` (the step's targets: any of them). */
export function sampleBoxes(doc: Document, target: StepTargets, extra: Element[] = []): BoxFrame {
  const frame: BoxFrame = new Map();
  const view = doc.defaultView;
  const width = view?.innerWidth ?? 0;
  const height = view?.innerHeight ?? 0;
  // The row opening at the very bottom moves as one: what it holds (a batch's message rows) rises
  // with its toggle and the text above, so it is the target's as much as the toggle's line is.
  const targets = targetList(target).map((each) => ({ each, folding: bottomFoldOf(each) }));
  for (const element of new Set([...doc.querySelectorAll(TRACK_SELECTOR), ...extra])) {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= height || rect.left >= width) continue;
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
    frame.set(idOf(element), {
      box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      label: labelOf(element),
      targeted,
      after,
      before,
    });
  }
  return frame;
}

/** Most frames one tracker keeps (about 33 s at 60 Hz); a longer run scores its first frames. */
const MAX_FRAMES = 2000;

/** Samples every frame until `stop`, which scores what it saw. */
export function startBoxTracker(
  doc: Document,
  options: { target?: StepTargets; extra?: () => Element[]; firstMoveFree?: boolean; restedAtStart?: boolean } = {},
): { stop(): BoxShift } {
  const frames: BoxFrame[] = [];
  const view = doc.defaultView!;
  let handle = 0;
  const sample = () => {
    if (frames.length < MAX_FRAMES) frames.push(sampleBoxes(doc, options.target ?? null, options.extra?.() ?? []));
    handle = view.requestAnimationFrame(sample);
  };
  sample();
  return {
    stop() {
      view.cancelAnimationFrame(handle);
      frames.push(sampleBoxes(doc, options.target ?? null, options.extra?.() ?? []));
      return scoreBoxFrames(frames, { width: view.innerWidth, height: view.innerHeight }, options);
    },
  };
}
