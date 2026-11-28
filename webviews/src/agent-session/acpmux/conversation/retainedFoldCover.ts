// Retained rows can have different fold clocks: a slide, a delayed slide, a dip, or the
// two stationary pictures of a swap. Bound their painted boxes without changing those clocks.
import { bezierAt, type CubicBezier } from "../../../ui/cubicBezier";

export type RetainedFoldPath = {
  node: HTMLElement;
  from: number;
  to: number;
  height: number;
  delay: number;
  ms: number;
  easing: string;
  mode: "move" | "jump" | "start" | "end";
  clip: Keyframe[];
  movable: boolean;
  snapshot?: boolean;
};

export type RetainedFoldEnvelope = {
  frames: Keyframe[];
  duration: number;
  easing: string;
  delay: number;
};

type Range = { low: number; high: number };
type Curve = {
  range: (low: number, high: number) => Range;
  monotone: boolean;
};
const unit = (n: number) => Math.max(0, Math.min(1, n));
const span = (a: number, b: number): Range => ({ low: Math.min(a, b), high: Math.max(a, b) });
const inset = (top: number, bottom: number) => `inset(${top}px -4096px ${bottom}px -4096px)`;
// CSS keyword definitions for interpreting an existing animation, not motion choices.
const cssCurves: Record<string, CubicBezier> = {
  ease: [0.25, 0.1, 0.25, 1],
  "ease-in": [0.42, 0, 1, 1],
  "ease-out": [0, 0, 0.58, 1],
  "ease-in-out": [0.42, 0, 0.58, 1],
};
const curves = new Map<string, Curve>();

// CSS linear() allows zero, one or two input percentages per output, with
// omitted positions distributed between their specified neighbours. Duplicate
// positions describe a jump; both sides count when bounding an interval.
function parseLinearStops(stops: readonly string[]): { x: number; y: number }[] | undefined {
  const points: { x?: number; y: number }[] = [];
  for (const stop of stops) {
    const parts = stop.trim().split(/\s+/);
    const y = Number(parts[0]);
    if (!Number.isFinite(y) || parts.length > 3) return undefined;
    const positions = parts
      .slice(1)
      .map((position) => (position.endsWith("%") ? Number(position.slice(0, -1)) / 100 : NaN));
    if (positions.some((x) => !Number.isFinite(x))) return undefined;
    if (positions.length) for (const x of positions) points.push({ x, y });
    else points.push({ y });
  }
  if (points.length < 2) return undefined;
  points[0]!.x ??= 0;
  points[points.length - 1]!.x ??= 1;
  let previous = points[0]!.x!;
  for (const point of points)
    if (point.x !== undefined) {
      point.x = Math.max(previous, point.x);
      previous = point.x;
    }
  let left = 0;
  for (let right = 1; right < points.length; right += 1) {
    if (points[right]!.x === undefined) continue;
    for (let at = left + 1; at < right; at += 1)
      points[at]!.x = points[left]!.x! + ((points[right]!.x! - points[left]!.x!) * (at - left)) / (right - left);
    left = right;
  }
  return points as { x: number; y: number }[];
}

function curve(text: string): Curve {
  const cached = curves.get(text);
  if (cached) return cached;
  const easing = text.trim();
  let result: Curve;
  if (easing === "linear") {
    result = { range: (a, b) => span(unit(a), unit(b)), monotone: true };
  } else {
    // Unlike the curve editor's parser, CSS permits arbitrary y control points. Include
    // derivative roots, so an overshooting custom curve is bounded by its extrema too.
    const cubic = cssCurves[easing] ?? /^cubic-bezier\(([^)]+)\)$/.exec(easing)?.[1]?.split(",").map(Number);
    const linear = /^linear\(([^)]+)\)$/
      .exec(easing)?.[1]
      ?.split(",")
      .map((n) => n.trim());
    if (cubic?.length === 4 && cubic.every(Number.isFinite)) {
      const bezier = cubic as unknown as CubicBezier;
      const [x1, y1, x2, y2] = bezier;
      const a = 3 * y1 - 3 * y2 + 1;
      const b = 2 * (y2 - 2 * y1);
      const c = y1;
      const roots =
        Math.abs(a) < 1e-12
          ? Math.abs(b) < 1e-12
            ? []
            : [-c / b]
          : b * b - 4 * a * c < 0
            ? []
            : [(-b - Math.sqrt(b * b - 4 * a * c)) / (2 * a), (-b + Math.sqrt(b * b - 4 * a * c)) / (2 * a)];
      const extrema = roots
        .filter((t) => t > 0 && t < 1)
        .map((t) => 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t ** 2 * x2 + t ** 3);
      result = {
        range: (low, high) => {
          const a = unit(low);
          const b = unit(high);
          const values = [
            bezierAt(bezier, a),
            bezierAt(bezier, b),
            ...extrema.filter((x) => x > a && x < b).map((x) => bezierAt(bezier, x)),
          ];
          return { low: Math.min(...values), high: Math.max(...values) };
        },
        monotone: extrema.length === 0 && y1 >= 0 && y2 <= 1,
      };
    } else if (linear && parseLinearStops(linear)) {
      const points = parseLinearStops(linear)!;
      const value = (input: number) => {
        const x = unit(input);
        let low = 0;
        while (low < points.length - 2 && points[low + 1]!.x <= x) low += 1;
        // CSS extrapolates from its first/last nonzero interval outside the stops.
        if (x < points[0]!.x) while (low < points.length - 2 && points[low + 1]!.x === points[low]!.x) low += 1;
        let high = low + 1;
        while (high < points.length - 1 && points[high]!.x === points[low]!.x) high += 1;
        const a = points[low]!;
        const b = points[high]!;
        return b.x === a.x ? b.y : a.y + ((b.y - a.y) * (x - a.x)) / (b.x - a.x);
      };
      result = {
        range: (a, b) => {
          const values = [value(a), value(b)];
          for (const point of points) if (point.x >= unit(a) && point.x <= unit(b)) values.push(point.y);
          return { low: Math.min(...values), high: Math.max(...values) };
        },
        monotone: value(0) === 0 && value(1) === 1 && points.every((p, i) => i === 0 || p.y >= points[i - 1]!.y),
      };
    } else {
      // steps() stays in [0,1]. A linear() with explicit stops can overshoot; its
      // output values bound the entire interpolation, even without parsing its stops.
      const values = linear?.map((point) => Number.parseFloat(point)).filter(Number.isFinite) ?? [];
      result = { range: () => ({ low: Math.min(0, ...values), high: Math.max(1, ...values) }), monotone: false };
    }
  }
  // The app's finite easing palette is reused every pass; bound custom editor values too.
  if (curves.size >= 64) curves.clear();
  curves.set(text, result);
  return result;
}

function clipSides(frame: Keyframe): { top: number; bottom: number } {
  const sides = /^inset\(([^)]+)\)/
    .exec(String(frame.clipPath ?? ""))?.[1]
    ?.split(/\s+/)
    .map(Number.parseFloat);
  return { top: Math.max(0, sides?.[0] ?? 0), bottom: Math.max(0, sides?.[2] ?? sides?.[0] ?? 0) };
}

function clipRange(path: RetainedFoldPath, low: number, high: number) {
  const frames = path.clip;
  if (frames.length === 0) return { top: 0, bottom: 0, minTop: 0, minBottom: 0 };
  const progress = curve(path.mode === "jump" ? "linear" : path.easing).range(low, high);
  let top = 0;
  let minTop = Infinity;
  let bottom = 0;
  let minBottom = Infinity;
  const take = (a: { top: number; bottom: number }, b: { top: number; bottom: number }, range: Range) => {
    const upper = span(a.top + (b.top - a.top) * range.low, a.top + (b.top - a.top) * range.high);
    top = Math.max(top, upper.high);
    minTop = Math.min(minTop, upper.low);
    const ends = span(a.bottom + (b.bottom - a.bottom) * range.low, a.bottom + (b.bottom - a.bottom) * range.high);
    bottom = Math.max(bottom, ends.high);
    minBottom = Math.min(minBottom, ends.low);
  };
  // Animation-level easing can overshoot its keyframe interval. A two-frame
  // clip extrapolates there too; clamping its progress would reopen the baseline
  // top cover (or bottom reveal) while a custom spring is still outside [0,1].
  if (
    frames.length === 2 &&
    (frames[0]!.offset ?? 0) === 0 &&
    (frames[1]!.offset ?? 1) === 1 &&
    (!frames[0]!.easing || frames[0]!.easing === "linear")
  ) {
    take(clipSides(frames[0]!), clipSides(frames[1]!), progress);
    return { top, bottom, minTop: Math.max(0, minTop), minBottom: Math.max(0, minBottom) };
  }
  for (let i = 0; i < frames.length - 1; i += 1) {
    const start = frames[i]!.offset ?? i / (frames.length - 1);
    const end = frames[i + 1]!.offset ?? (i + 1) / (frames.length - 1);
    if (end < progress.low || start > progress.high) continue;
    const range =
      end === start
        ? { low: 0, high: 1 }
        : curve(frames[i]!.easing ?? "linear").range(
            (Math.max(start, progress.low) - start) / (end - start),
            (Math.min(end, progress.high) - start) / (end - start),
          );
    take(clipSides(frames[i]!), clipSides(frames[i + 1]!), range);
  }
  if (!Number.isFinite(minBottom)) {
    const sides = clipSides(frames[progress.low >= 1 ? frames.length - 1 : 0]!);
    return { ...sides, minTop: sides.top, minBottom: sides.bottom };
  }
  return { top, bottom, minTop: Math.max(0, minTop), minBottom: Math.max(0, minBottom) };
}

function topRange(path: RetainedFoldPath, low: number, high: number): Range {
  if (!path.movable || path.mode === "end") return span(path.to, path.to);
  if (path.mode === "start") return span(path.from, path.from);
  if (path.mode === "jump") {
    if (high < 0.35) return span(path.from, path.from);
    if (low >= 0.35) return span(path.to, path.to);
    return span(path.from, path.to);
  }
  const progress = curve(path.easing).range(low, high);
  return span(path.from + (path.to - path.from) * progress.low, path.from + (path.to - path.from) * progress.high);
}

/** One group is one retained row; its live node and swap snapshot never cover each other. */
export function retainedFoldCover(
  groups: readonly (readonly RetainedFoldPath[])[],
): Map<HTMLElement, RetainedFoldEnvelope> {
  const output = new Map<HTMLElement, RetainedFoldEnvelope>();
  const paths = groups.flat();
  const movers = paths.filter((path) => path.movable);
  const first = movers[0];
  if (!first) return output;
  // A visible row that does not move is still an obstacle, even when DOM order
  // temporarily puts a moving row on its other side. Keep the static text whole
  // and clip the mover against its nearest stationary neighbours at the landing.
  const statics = groups.flatMap((group, owner) =>
    group.flatMap((path) =>
      !path.movable && path.height > 0 ? [{ owner, top: path.to, bottom: path.to + path.height }] : [],
    ),
  );
  const above = [...statics].sort((a, b) => a.bottom - b.bottom);
  const below = [...statics].sort((a, b) => a.top - b.top);
  const staticBounds = new Map<RetainedFoldPath, { above: number; below: number }>();
  groups.forEach((group, owner) =>
    group.forEach((path) => {
      if (!path.movable) return;
      let low = 0;
      let high = above.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (above[middle]!.bottom <= path.to) low = middle + 1;
        else high = middle;
      }
      let at = low - 1;
      // One live row and its snapshot form a group. A stationary live row must not
      // cover its own snapshot; there is at most one stationary entry per group.
      if (above[at]?.owner === owner) at -= 1;
      const upper = above[at]?.bottom ?? -Infinity;
      low = 0;
      high = below.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (below[middle]!.top < path.to + path.height) low = middle + 1;
        else high = middle;
      }
      if (below[low]?.owner === owner) low += 1;
      staticBounds.set(path, { above: upper, below: below[low]?.top ?? Infinity });
    }),
  );

  // A common monotone clock has an exact endpoint proof: each box and its clip use
  // the same progress. Keep the existing curve and fractional clip in that case.
  const shared =
    movers.every(
      (path) =>
        path.mode === "move" &&
        path.delay === first.delay &&
        path.ms === first.ms &&
        path.easing === first.easing &&
        path.clip.length <= 2 &&
        path.clip.every((frame) => !frame.easing || frame.easing === "linear"),
    ) && curve(first.easing).monotone;
  if (shared) {
    let lowerFrom = Infinity;
    let lowerTo = Infinity;
    for (let i = groups.length - 1; i >= 0; i -= 1) {
      for (const path of groups[i]!) {
        if (!path.movable) continue;
        const start = clipSides(path.clip[0] ?? {});
        const end = clipSides(path.clip.at(-1) ?? {});
        const stationary = staticBounds.get(path)!;
        const topFrom = Math.max(start.top, stationary.above - path.from, 0);
        const topTo = Math.max(end.top, stationary.above - path.to, 0);
        const bottomFrom = Math.max(start.bottom, path.from + path.height - Math.min(lowerFrom, stationary.below), 0);
        const bottomTo = Math.max(end.bottom, path.to + path.height - Math.min(lowerTo, stationary.below), 0);
        if (topFrom > start.top || topTo > end.top || bottomFrom > start.bottom || bottomTo > end.bottom)
          output.set(path.node, {
            frames: [{ clipPath: inset(topFrom, bottomFrom) }, { clipPath: inset(topTo, bottomTo) }],
            duration: first.ms,
            easing: first.easing,
            delay: first.delay,
          });
      }
      for (const path of groups[i]!) {
        if (!path.movable) continue;
        lowerFrom = Math.min(lowerFrom, path.movable ? path.from : path.to);
        lowerTo = Math.min(lowerTo, path.to);
      }
    }
    return output;
  }
  const duration = Math.max(...paths.map((path) => path.delay + path.ms));
  if (duration <= 0) return output;
  // Fixed subdivision only tightens the bounds. Each interval uses all extrema,
  // not samples, so adding rows/delays cannot increase the number of intervals.
  const steps = 32;
  const bands = paths.map(() => [] as { top: number; bottom: number }[]);
  const needed = paths.map(() => false);
  const index = new Map(paths.map((path, i) => [path, i]));
  for (let step = 0; step < steps; step += 1) {
    const from = (duration * step) / steps;
    const to = (duration * (step + 1)) / steps;
    const boxes = paths.map((path) => {
      const low = (from - path.delay) / Math.max(1, path.ms);
      const high = (to - path.delay) / Math.max(1, path.ms);
      const top = topRange(path, low, high);
      return { top, clip: clipRange(path, low, high), active: !(path.snapshot && from >= path.delay + path.ms) };
    });
    // Descending bottom coordinates let a prefix-min Fenwick tree answer:
    // nearest lower top among boxes whose bottom can reach this row's top.
    const bottoms = [...new Set(boxes.flatMap((box, i) => (box.active ? [box.top.high + paths[i]!.height] : [])))].sort(
      (a, b) => b - a,
    );
    const ranks = new Map(bottoms.map((bottom, i) => [bottom, i + 1]));
    const tree = Array.from({ length: bottoms.length + 1 }, () => Infinity);
    const add = (bottom: number, top: number) => {
      for (let i = ranks.get(bottom)!; i < tree.length; i += i & -i) tree[i] = Math.min(tree[i]!, top);
    };
    const nearest = (top: number) => {
      let low = 0;
      let high = bottoms.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (bottoms[middle]! > top) low = middle + 1;
        else high = middle;
      }
      let value = Infinity;
      for (let i = low; i > 0; i -= i & -i) value = Math.min(value, tree[i]!);
      return value;
    };
    for (let group = groups.length - 1; group >= 0; group -= 1) {
      for (const path of groups[group]!) {
        const i = index.get(path)!;
        const box = boxes[i]!;
        const stationary = staticBounds.get(path);
        const topClearance = (stationary?.above ?? -Infinity) - box.top.low;
        const clearance = box.top.high + path.height - Math.min(nearest(box.top.low), stationary?.below ?? Infinity);
        if (
          path.movable &&
          box.active &&
          (clearance > box.clip.minBottom + 0.001 || topClearance > box.clip.minTop + 0.001)
        )
          needed[i] = true;
        bands[i]!.push({
          top: Math.max(box.clip.top, box.active ? topClearance : 0, 0),
          bottom: Math.max(box.clip.bottom, box.active ? clearance : 0, 0),
        });
      }
      for (const path of groups[group]!) {
        const box = boxes[index.get(path)!]!;
        if (path.movable && box.active) add(box.top.high + path.height, box.top.low);
      }
    }
  }
  paths.forEach((path, i) => {
    if (!path.movable || !needed[i]) return;
    const frames: Keyframe[] = [];
    for (let step = 0; step <= steps; step += 1) {
      const before = bands[i]![Math.max(0, step - 1)]!;
      const after = bands[i]![Math.min(steps - 1, step)]!;
      // Both ends dominate the entire interval, so interpolation cannot expose ink
      // between inspected points, including a jump or a nonmonotone spring peak.
      const top = Math.ceil(Math.max(before.top, after.top));
      const bottom = Math.ceil(Math.max(before.bottom, after.bottom));
      frames.push({ offset: step / steps, clipPath: inset(top, bottom) });
    }
    // The exact end is settled layout (and snapshots are transparent). A duplicate
    // endpoint removes coverage then, never by opening it early in the last segment.
    frames.push({ offset: 1, clipPath: inset(0, 0) });
    output.set(path.node, { frames, duration, easing: "linear", delay: 0 });
  });
  return output;
}
