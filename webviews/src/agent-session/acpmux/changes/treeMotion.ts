// The changes tree's folder disclosure motion, as pure functions (treeMotionDom.ts applies them to
// the rows of the Pierre tree). The arms are the experiment `diff-tree-disclosure`
// (treeMotion.experiment.ts).
//
// The DOM always holds the final layout: Pierre inserts or removes a folder's rows at once. The
// motion is drawn over it with transforms, opacity and clip only, never height, so no frame lays
// out. Each animating folder F has an openness q(t) from its spring (0 closed, 1 open):
//   - rows after F's block ("following") move with F's edge: in the open layout by -H + q*T, in
//     the closed layout by q*T, where H is the block's height and T its travel (H, or for arm f
//     at most the room below F, so a 100-file folder opens as fast as a 3-file one);
//   - F's descendants show only between F's bottom and the edge (F's bottom + q*T): a clip, so
//     they never overlap the following rows; per arm they also slide (the drawer of d and f, the
//     8 px of b) and fade (b, c with a stagger, f softly);
//   - F's chevron turns by -90 * (1 - q) degrees from its final angle.
// The rows a collapse removes, and rows an expansion pushes out of the rendered window, stay as
// ghost copies until the motion ends. A second toggle reverses from the q on screen: the motion
// is a function of q, so a reversal never jumps. Reduced motion (and arm e) snaps the layout and
// only crossfades the new rows in.
import {
  MOTION_FADES,
  MOTION_SPRINGS,
  springStepResponse,
  springVisibleEnd,
  type SpringParameters,
} from "../../../files-panel-motion";

export type TreeArm = "a" | "b" | "c" | "d" | "e" | "f";

/** How one arm moves: everything a planner needs, no DOM. */
export type ArmMotion = {
  /** none: today's instant layout; snap: instant plus a crossfade (and a tint for arm e); spring: q animates. */
  kind: "none" | "snap" | "spring";
  open: SpringParameters;
  close: SpringParameters;
  /** Descendants move with the edge, as if pulled out from under the folder row. */
  drawer: boolean;
  /** Descendants start this many px above their place and slide down (arm b). */
  slidePx: number;
  /** Descendant opacity: none (always 1), linear (q), stagger (per row, offset in time), soft (0.4 to 1). */
  fade: "none" | "linear" | "stagger" | "soft";
  /** Stagger between successive descendants, in ms of the spring's visible length (arm c). */
  staggerMs: number;
  /** Travel at most the room below the folder (arm f). */
  capTravel: boolean;
  /** Snap arms: the new rows' tint fades out over `highlight` (arm e). */
  tint: boolean;
};

const base: ArmMotion = {
  kind: "spring",
  open: MOTION_SPRINGS.appear,
  close: MOTION_SPRINGS.disappear,
  drawer: false,
  slidePx: 0,
  fade: "none",
  staggerMs: 0,
  capTravel: false,
  tint: false,
};

export const TREE_ARMS: Record<TreeArm, ArmMotion> = {
  a: { ...base, kind: "none" },
  b: { ...base, slidePx: 8, fade: "linear" },
  c: { ...base, open: MOTION_SPRINGS.move, close: MOTION_SPRINGS.move, fade: "stagger", staggerMs: 15 },
  d: { ...base, drawer: true },
  e: { ...base, kind: "snap", tint: true },
  f: { ...base, drawer: true, fade: "soft", capTravel: true },
};

/** Reduce Motion: no movement; new rows crossfade in (motion.md rule 7). Arm a stays instant. */
export function effectiveArm(arm: TreeArm, reducedMotion: boolean): ArmMotion {
  const motion = TREE_ARMS[arm];
  if (!reducedMotion || motion.kind === "none") return motion;
  return { ...motion, kind: "snap", tint: false };
}

/** One folder's running disclosure. Times in ms on the document timeline. */
export type FolderMotion = {
  /** The folder row's path. */
  path: string;
  /** The state the DOM shows (the target). */
  open: boolean;
  /** Openness when this motion started, and when. */
  q0: number;
  start: number;
  spring: SpringParameters;
  duration: number;
  /** Height of the folder's visible descendants in the open layout, and the travel shown. */
  height: number;
  travel: number;
  /** The folder row's top in list coordinates (current DOM layout) and its height. */
  top: number;
  rowHeight: number;
};

export function springDurationMs(spring: SpringParameters): number {
  return Math.round(springVisibleEnd(spring) * 1000);
}

/** Openness of `folder` at `time` (ms). */
export function openness(folder: FolderMotion, time: number): number {
  const target = folder.open ? 1 : 0;
  const elapsed = time - folder.start;
  if (elapsed >= folder.duration) return target;
  if (elapsed <= 0) return folder.q0;
  return folder.q0 + (target - folder.q0) * springStepResponse(folder.spring, elapsed / 1000);
}

/** Starts (or retargets from its current openness) the motion of a folder that just toggled. */
export function startFolder(
  previous: FolderMotion | undefined,
  next: Omit<FolderMotion, "q0" | "start" | "spring" | "duration">,
  arm: ArmMotion,
  now: number,
): FolderMotion {
  const spring = next.open ? arm.open : arm.close;
  const q0 = previous ? openness(previous, now) : next.open ? 0 : 1;
  return { ...next, q0, start: now, spring, duration: springDurationMs(spring) };
}

/** The travel a block of `height` px shows: all of it, or (capped) the room below the folder row. */
export function travelFor(height: number, room: number, arm: ArmMotion): number {
  return arm.capTravel ? Math.max(0, Math.min(height, Math.max(room, 0))) : height;
}

/** A row's place relative to one folder. */
export type Relation = "before" | "self" | "descendant" | "following";

/** Folder paths end with "/" (or are compared as if they did), so `src/a` is not under `src/ab`. */
const asFolder = (path: string) => (path.endsWith("/") ? path : `${path}/`);

export function relation(rowPath: string, rowTop: number, folder: Pick<FolderMotion, "path" | "top">): Relation {
  if (rowPath === folder.path) return "self";
  if (rowPath.startsWith(asFolder(folder.path))) return "descendant";
  return rowTop > folder.top ? "following" : "before";
}

/** What one row looks like at a time: an offset, a visible band (list coordinates), an opacity. */
export type RowVisual = { y: number; clipTop: number; clipBottom: number; opacity: number; rotate: number };

/**
 * A row's look at `time` under every running folder motion. `top` is its layout top (a ghost's
 * is where it would be in the open layout).
 */
export function rowVisual(
  row: { path: string; top: number; height: number },
  folders: readonly FolderMotion[],
  arm: ArmMotion,
  time: number,
): RowVisual {
  let y = 0;
  let clipTop = Number.NEGATIVE_INFINITY;
  let clipBottom = Number.POSITIVE_INFINITY;
  let opacity = 1;
  let rotate = 0;
  // Folders in layout order, so an outer folder's offset applies before an inner folder's band.
  const ordered = [...folders].sort((a, b) => a.top - b.top);
  for (const folder of ordered) {
    const q = openness(folder, time);
    const rel = relation(row.path, row.top, folder);
    if (rel === "self") {
      rotate += folder.open ? -90 * (1 - q) : 90 * q;
    } else if (rel === "following") {
      y += folder.open ? -folder.height + q * folder.travel : q * folder.travel;
    } else if (rel === "descendant") {
      // The folder row's own offset: from the folders around it.
      const own = rowVisual(
        { path: folder.path, top: folder.top, height: folder.rowHeight },
        ordered.filter((other) => other !== folder),
        arm,
        time,
      ).y;
      const bottom = folder.top + folder.rowHeight + own;
      const index = Math.max(0, Math.round((row.top - folder.top - folder.rowHeight) / folder.rowHeight));
      if (arm.drawer) y += -(1 - q) * folder.travel;
      if (arm.slidePx) y += -(1 - q) * arm.slidePx;
      clipTop = Math.max(clipTop, bottom);
      clipBottom = Math.min(clipBottom, bottom + q * folder.travel);
      opacity *= descendantOpacity(arm, q, index, folder.duration);
    }
  }
  return { y, clipTop, clipBottom, opacity, rotate };
}

function descendantOpacity(arm: ArmMotion, q: number, index: number, durationMs: number): number {
  switch (arm.fade) {
    case "none":
      return 1;
    case "linear":
      return q;
    case "soft":
      return 0.4 + 0.6 * q;
    case "stagger": {
      // Row i fades over the window of q from i * delay to i * delay + width (at most 8 rows of delay).
      const delay = Math.min(index, 8) * (arm.staggerMs / Math.max(durationMs, 1));
      const width = 0.5;
      return Math.max(0, Math.min(1, (q - delay) / width));
    }
  }
}

/** Sample times from `now` until every folder's motion has ended (about 120 Hz, at most 48). */
export function sampleTimes(folders: readonly FolderMotion[], now: number): number[] {
  const end = Math.max(now, ...folders.map((folder) => folder.start + folder.duration));
  const span = end - now;
  if (span <= 0) return [now];
  const count = Math.min(48, Math.max(2, Math.ceil(span / 8.33)));
  return Array.from({ length: count + 1 }, (_, index) => now + (span * index) / count);
}

const round = (value: number) => Math.round(value * 100) / 100;

/** The clip of a row band, as an inset() of the row's own box; null when nothing is clipped. */
export function clipInset(visual: RowVisual, top: number, height: number): { top: number; bottom: number } | null {
  const shown = top + visual.y;
  const insetTop = Math.max(0, visual.clipTop - shown);
  const insetBottom = Math.max(0, shown + height - visual.clipBottom);
  if (insetTop <= 0 && insetBottom <= 0) return null;
  return { top: Math.min(height, round(insetTop)), bottom: Math.min(height, round(insetBottom)) };
}

/**
 * Web Animation keyframes for one row from `times[0]` to the end (linear between samples), or null
 * when the row does not change. `chevron` gets its own keyframes (its turn).
 */
export function rowKeyframes(
  row: { path: string; top: number; height: number },
  folders: readonly FolderMotion[],
  arm: ArmMotion,
  times: readonly number[],
): { row: Keyframe[] | null; chevron: Keyframe[] | null } {
  const visuals = times.map((time) => rowVisual(row, folders, arm, time));
  const moves = visuals.some((visual) => Math.abs(visual.y) > 0.01);
  const fades = visuals.some((visual) => visual.opacity < 0.999);
  const insets = visuals.map((visual) => clipInset(visual, row.top, row.height));
  const clips = insets.some(Boolean);
  const turns = visuals.some((visual) => Math.abs(visual.rotate) > 0.01);
  const span = times[times.length - 1]! - times[0]!;
  const offset = (index: number) =>
    span > 0 ? (times[index]! - times[0]!) / span : index / Math.max(1, times.length - 1);
  const rowFrames =
    moves || fades || clips
      ? visuals.map((visual, index) => {
          const frame: Keyframe = { offset: offset(index) };
          if (moves) frame.transform = `translate3d(0, ${round(visual.y)}px, 0)`;
          if (fades) frame.opacity = round(visual.opacity);
          if (clips) {
            const inset = insets[index];
            frame.clipPath = inset
              ? `inset(${inset.top}px -100vw ${inset.bottom}px -100vw)`
              : "inset(0px -100vw 0px -100vw)";
          }
          return frame;
        })
      : null;
  const chevronFrames = turns
    ? visuals.map((visual, index) => ({ offset: offset(index), rotate: `${round(visual.rotate)}deg` }))
    : null;
  return { row: rowFrames, chevron: chevronFrames };
}

/** Snap arms: the crossfade of a row that just appeared (and arm e's tint, in `accent`). */
export function snapKeyframes(
  arm: ArmMotion,
  accent: string,
): { fade: { keyframes: Keyframe[]; duration: number }; tint?: { keyframes: Keyframe[]; duration: number } } {
  const fade = { keyframes: [{ opacity: 0 }, { opacity: 1 }], duration: MOTION_FADES.crossfade };
  if (!arm.tint) return { fade };
  return {
    fade,
    tint: {
      keyframes: [
        { backgroundColor: `color-mix(in srgb, ${accent} 22%, transparent)`, easing: "ease-out" },
        { backgroundColor: `color-mix(in srgb, ${accent} 0%, transparent)` },
      ],
      duration: MOTION_FADES.highlight,
    },
  };
}
