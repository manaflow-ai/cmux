// The layout-motion contract (schemas/layout-motion/contract.json), read by the pages. Leo, 2026-11-18:
// "I was thinking we'd be able to calculate each beforehand everything that would move and just go ok
// well nothing else usually should and the things that move we only expect at certain times etc ...
// Fundamentally". Each surface names where its size comes from before it mounts and the events on which
// one of its boxes may move. Code that moves something on purpose declares the move while it runs
// (`declareMove`); motionJudge.ts flags every other move.
import contract from "../../../schemas/layout-motion/contract.json";

export type MotionEvent = keyof typeof contract.events;
export type SizeSource = keyof typeof contract.sizes;
export type Surface = {
  id: string;
  platform: "web" | "native";
  selector?: string;
  view?: string;
  size: SizeSource;
  moves: readonly MotionEvent[];
};

export const MOTION_EVENTS = Object.keys(contract.events) as MotionEvent[];
export const SURFACES = contract.surfaces as readonly Surface[];
export const WEB_SURFACES = SURFACES.filter((surface) => surface.platform === "web" && surface.selector);
/** Frames a box must draw in one place before a move of it counts (it is still mounting until then). */
export const REST_FRAMES: number = contract.restFrames;
/** Moves and resizes under this many CSS px are layout rounding. */
export const SLACK_PX: number = contract.slackPx;

const byId = new Map(SURFACES.map((surface) => [surface.id, surface]));
export const surfaceById = (id: string | null | undefined): Surface | undefined => (id ? byId.get(id) : undefined);

/** The web surface an element belongs to: the first whose selector it matches, in contract order. An
 *  element the gallery tracks for an entry (an anchor) and no surface names is `tracked`. */
export function surfaceOf(element: Element): Surface {
  for (const surface of WEB_SURFACES) if (element.matches(surface.selector!)) return surface;
  return byId.get("tracked")!;
}

/**
 * A move a piece of code means, while it runs. `scope: "all"` covers every box whose surface allows the
 * event (a resize, a scroll, a stream following the end); `targets` covers the targets, what they hold,
 * what follows them pushed straight down, and while one is a fold at the very bottom of a followed
 * transcript, what precedes it rising straight up (an expand). `once`: each box may move once under
 * this declaration (a resize lays a box out once; a second move is a bounce).
 */
export type Declaration = {
  event: MotionEvent;
  scope: "all" | "targets";
  targets?: readonly Element[];
  once?: boolean;
  /** Who declared it, for the report. */
  by?: string;
};

type Open = Declaration & { key: number; until: number };

let nextKey = 1;
const open = new Map<number, Open>();

/**
 * Declares a move from now until `end()` is called or `ms` pass (the default holds it until `end()`).
 * Cheap when nothing audits: one map entry.
 */
export function declareMove(declaration: Declaration, options: { ms?: number } = {}): () => void {
  const key = nextKey++;
  const until = options.ms === undefined ? Number.POSITIVE_INFINITY : performance.now() + options.ms;
  open.set(key, { ...declaration, key, until });
  return () => void open.delete(key);
}

/** The declarations open now, each with a key that names it across frames (for `once`). */
export function openDeclarations(now = performance.now()): (Declaration & { key: number })[] {
  const live: (Declaration & { key: number })[] = [];
  for (const [key, declaration] of open) {
    if (declaration.until < now) open.delete(key);
    else live.push(declaration);
  }
  return live;
}
