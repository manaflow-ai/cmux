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
//   - the step's target, its ancestors and descendants (the tool row that expands);
//   - a box after the target in document order that moves straight down: the expansion pushes it;
//   - a box's first move after a resize (`firstMoveFree`): the new width lays it out once; a second
//     move is the bounce a sidebar toggle must not have;
//   - moves under half a CSS px (layout rounding), and boxes outside the viewport.
// The pure scoring is here (unit tested); `startBoxTracker` samples the live page.

export type Box = { x: number; y: number; width: number; height: number };

/** One tracked box in one frame. `after` is true when it follows the step's target in document order. */
export type BoxSample = { box: Box; label: string; targeted?: boolean; after?: boolean };
export type BoxFrame = Map<number, BoxSample>;

export type BoxMove = { label: string; frame: number; dx: number; dy: number };
export type BoxShift = { score: number; moves: BoxMove[] };

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

/** The tracked boxes now, with each one's relation to `target`. */
export function sampleBoxes(doc: Document, target: Element | null, extra: Element[] = []): BoxFrame {
  const frame: BoxFrame = new Map();
  const view = doc.defaultView;
  const width = view?.innerWidth ?? 0;
  const height = view?.innerHeight ?? 0;
  for (const element of new Set([...doc.querySelectorAll(TRACK_SELECTOR), ...extra])) {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= height || rect.left >= width) continue;
    const targeted = !!target && (element === target || element.contains(target) || target.contains(element));
    const after = !!target && !targeted && (target.compareDocumentPosition(element) & 4) !== 0; // 4: DOCUMENT_POSITION_FOLLOWING (no global Node in tests)
    frame.set(idOf(element), {
      box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      label: labelOf(element),
      targeted,
      after,
    });
  }
  return frame;
}

/** Most frames one tracker keeps (about 33 s at 60 Hz); a longer run scores its first frames. */
const MAX_FRAMES = 2000;

/** Samples every frame until `stop`, which scores what it saw. */
export function startBoxTracker(
  doc: Document,
  options: { target?: Element | null; extra?: () => Element[]; firstMoveFree?: boolean; restedAtStart?: boolean } = {},
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
