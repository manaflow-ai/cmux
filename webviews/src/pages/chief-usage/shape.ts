// Pure shaping for the Chief Usage page: dollars, token counts, percents and durations in the
// person's language (Intl, so no plural strings), bucket labels, and the chart geometry (stacked
// bars, lines, bands). The page, its gallery designs and its tests share these.
import type { UsageBucket, UsagePoint, UsageTokens } from "./types";

/** The four token kinds, bottom of the stack first. */
export const TOKEN_KINDS = ["input", "cache_read", "cache_write", "output"] as const;
export type TokenKind = (typeof TOKEN_KINDS)[number];

export const tokenTotal = (row: UsageTokens) => row.input + row.output + row.cache_read + row.cache_write;

/** `$41.20`, `$1,234`, `$0.0042`: cents under $100, whole dollars above, two significant digits under a cent. */
export function formatUSD(value: number, language: string): string {
  const options: Intl.NumberFormatOptions = { style: "currency", currency: "USD" };
  if (value > 0 && value < 0.01) options.maximumSignificantDigits = 2;
  else if (value >= 100) options.maximumFractionDigits = 0;
  else options.minimumFractionDigits = options.maximumFractionDigits = 2;
  return new Intl.NumberFormat(language, options).format(value);
}

/** `1.2M`, `845K`, `912` in the person's language. */
export function formatTokens(value: number, language: string): string {
  return new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

export function formatCount(value: number, language: string): string {
  return new Intl.NumberFormat(language).format(value);
}

/** `93.4%`; an en dash when there is no value (no prompt tokens). */
export function formatPercent(value: number | null | undefined, language: string): string {
  if (value === null || value === undefined) return "–";
  return new Intl.NumberFormat(language, { style: "percent", maximumFractionDigits: 1 }).format(value);
}

/** `850ms`, `6.1s`, `1m 5s`; an en dash when no turn ran. */
export function formatMs(ms: number | null | undefined, language: string): string {
  if (ms === null || ms === undefined) return "–";
  const unit = (value: number, name: "millisecond" | "second" | "minute", digits = 0) =>
    new Intl.NumberFormat(language, {
      style: "unit",
      unit: name,
      unitDisplay: "narrow",
      maximumFractionDigits: digits,
    }).format(value);
  if (ms < 1_000) return unit(Math.round(ms), "millisecond");
  if (ms < 60_000) return unit(ms / 1_000, "second", ms < 10_000 ? 1 : 0);
  const seconds = Math.round(ms / 1_000);
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return rest === 0 ? unit(minutes, "minute") : `${unit(minutes, "minute")} ${unit(rest, "second")}`;
}

/** The short axis label of a bucket starting at `t`: `14`, `Oct 19`, `Oct '26`. */
export function bucketLabel(t: number, bucket: UsageBucket, language: string, timeZone?: string): string {
  const options: Intl.DateTimeFormatOptions =
    bucket === "hour"
      ? { hour: "numeric" }
      : bucket === "month"
        ? { month: "short", year: "2-digit" }
        : { month: "short", day: "numeric" };
  return new Intl.DateTimeFormat(language, { ...options, timeZone }).format(t);
}

/** The tooltip title of a bucket: `Mon, Oct 19, 2 PM`, `Mon, Oct 19`, `October 2026`. */
export function bucketTitle(t: number, bucket: UsageBucket, language: string, timeZone?: string): string {
  const options: Intl.DateTimeFormatOptions =
    bucket === "hour"
      ? { weekday: "short", month: "short", day: "numeric", hour: "numeric" }
      : bucket === "month"
        ? { month: "long", year: "numeric" }
        : { weekday: "short", month: "short", day: "numeric" };
  return new Intl.DateTimeFormat(language, { ...options, timeZone }).format(t);
}

/** A moment of a top unit: `Oct 19, 14:05` in the person's language. */
export function formatWhen(ts: number, language: string, timeZone?: string): string {
  return new Intl.DateTimeFormat(language, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZone,
  }).format(ts);
}

/** The smallest 1, 2 or 5 × 10^n at or above `value`, so axis ticks land on round numbers. */
export function niceMax(value: number): number {
  if (!(value > 0)) return 1;
  const power = 10 ** Math.floor(Math.log10(value));
  for (const step of [1, 2, 5, 10]) if (step * power >= value) return step * power;
  return 10 * power;
}

/** The plot area inside an SVG of `width` × `height`, after its axis margins. */
export interface Plot {
  width: number;
  height: number;
  left: number;
  right: number;
  top: number;
  bottom: number;
}

export const innerWidth = (plot: Plot) => plot.width - plot.left - plot.right;
export const innerHeight = (plot: Plot) => plot.height - plot.top - plot.bottom;

export interface BarSegment {
  kind: TokenKind;
  value: number;
  y: number;
  height: number;
}

export interface StackedBar {
  index: number;
  /** The bucket's slot: the hover target spans it. */
  slotX: number;
  slotWidth: number;
  /** The drawn bar inside the slot. */
  x: number;
  width: number;
  /** Bottom first; empty kinds left out. */
  segments: BarSegment[];
  total: number;
}

/** The surface gap between stacked segments, per the dataviz mark spec. */
const SEGMENT_GAP = 2;

/**
 * One bar per bucket with its token kinds stacked from the baseline, scaled so `max` reaches the
 * top. A segment keeps at least 1px so a small kind still shows; gaps come out of the segment
 * above, never off the bar's total height.
 */
export function stackedBars(series: UsagePoint[], plot: Plot, max: number): StackedBar[] {
  const slot = innerWidth(plot) / Math.max(1, series.length);
  const width = Math.max(1, Math.min(28, slot * 0.72));
  const scale = innerHeight(plot) / Math.max(1, max);
  const baseline = plot.height - plot.bottom;
  return series.map((point, index) => {
    let y = baseline;
    const segments: BarSegment[] = [];
    for (const kind of TOKEN_KINDS) {
      const value = point[kind];
      if (value <= 0) continue;
      const full = Math.max(1, value * scale);
      const gap = segments.length ? Math.min(SEGMENT_GAP, full / 2) : 0;
      const height = Math.max(1, full - gap);
      y -= full;
      segments.push({ kind, value, y, height });
    }
    const slotX = plot.left + index * slot;
    return { index, slotX, slotWidth: slot, x: slotX + (slot - width) / 2, width, segments, total: tokenTotal(point) };
  });
}

/** The x of bucket `index`'s center. */
export function slotCenter(index: number, count: number, plot: Plot): number {
  return plot.left + (index + 0.5) * (innerWidth(plot) / Math.max(1, count));
}

/** The y of `value` on a 0..`max` scale. */
export function scaleY(value: number, max: number, plot: Plot): number {
  return plot.height - plot.bottom - (value / Math.max(Number.EPSILON, max)) * innerHeight(plot);
}

/**
 * An SVG path through each bucket center; a null value breaks the line (no turn, no prompt
 * tokens), so a gap never draws as a drop to zero. A lone point between gaps is a dot-sized move.
 */
export function linePath(values: (number | null)[], max: number, plot: Plot): string {
  let path = "";
  let drawing = false;
  values.forEach((value, index) => {
    if (value === null || !Number.isFinite(value)) {
      drawing = false;
      return;
    }
    const x = slotCenter(index, values.length, plot).toFixed(1);
    const y = scaleY(value, max, plot).toFixed(1);
    path += `${drawing ? "L" : "M"}${x},${y}`;
    drawing = true;
  });
  return path;
}

/** The filled area between `low` and `high` per bucket, broken where either is null. */
export function bandPath(low: (number | null)[], high: (number | null)[], max: number, plot: Plot): string {
  const runs: number[][] = [];
  let run: number[] = [];
  low.forEach((value, index) => {
    if (value === null || high[index] === null || high[index] === undefined) {
      if (run.length) runs.push(run);
      run = [];
    } else run.push(index);
  });
  if (run.length) runs.push(run);
  const count = low.length;
  return runs
    .map((indices) => {
      const top = indices.map((index) => {
        const x = slotCenter(index, count, plot).toFixed(1);
        return `${x},${scaleY(high[index]!, max, plot).toFixed(1)}`;
      });
      const bottom = [...indices].reverse().map((index) => {
        const x = slotCenter(index, count, plot).toFixed(1);
        return `${x},${scaleY(low[index]!, max, plot).toFixed(1)}`;
      });
      return `M${top.join("L")}L${bottom.join("L")}Z`;
    })
    .join("");
}

/**
 * Which bucket labels the x axis shows: about `room` of them, evenly spaced, last one always.
 */
export function axisLabelIndexes(count: number, room: number): number[] {
  if (count <= 0) return [];
  const step = Math.max(1, Math.ceil(count / Math.max(1, room)));
  const indexes: number[] = [];
  for (let index = count - 1; index >= 0; index -= step) indexes.unshift(index);
  return indexes;
}
