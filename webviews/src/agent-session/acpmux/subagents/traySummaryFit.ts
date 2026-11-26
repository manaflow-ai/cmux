// Which step the composer hat's `summary` header draws at a width (trayFoldHead.experiment.ts; Leo,
// 2026-11-23: "x subagents running y commands running etc with full text when you have space and it
// gradually shrinks when there is none... and have it not shift too much").
//
// The steps, richest first, each one whole line (every kind moves together, so the line never mixes
// "2 subagents running" with a bare "1"):
//   named    a lone item by its name ("Review the tray columns"), only when one thing runs
//   long     "2 subagents running · 1 command running"
//   short    "2 subagents · 1 command"
//   count    each kind's mark and its number (the `tally` arm's line)
//   +N       the count line with its trailing kinds folded into "+N" (hover names them)
// Pure: widths in, step out. The header measures each kind's forms once per change of its kinds, not
// per tick, and asks again when its box resizes.

export type SummaryForm = "named" | "long" | "short" | "count";

/// One kind's drawn width in each form, mark included. `named` only for a lone item.
export type SummaryKindWidths = { named?: number; long: number; short: number; count: number };

export type SummaryWidths = {
  kinds: readonly SummaryKindWidths[];
  /// The separator between kinds in the word steps (" · ").
  separator: number;
  /// The gap between kinds in the count steps.
  gap: number;
  /// The "+N" chip at its widest.
  more: number;
};

/// A step: the form every drawn kind takes, and how many kinds are drawn (the rest are "+N").
export type SummaryStep = { form: SummaryForm; shown: number };

/// How much wider than a richer step's need the box must be before the header grows into it: a box
/// resizing across a boundary by a pixel or two never flaps between two steps.
export const SUMMARY_HYSTERESIS_PX = 12;

// Steps as levels, richest first: 0 named, 1 long, 2 short, 3 count, 3 + j count with j kinds folded.
const FORMS: readonly SummaryForm[] = ["named", "long", "short", "count"];
const COUNT = 3;
/// The first count level (each kind's mark and number), for an arm that never draws words.
export const SUMMARY_COUNT_LEVEL = COUNT;

function lastLevel(widths: SummaryWidths): number {
  // At least one kind stays drawn beside the "+N".
  return COUNT + Math.max(0, widths.kinds.length - 1);
}

function firstLevel(widths: SummaryWidths): number {
  return widths.kinds.length === 1 && widths.kinds[0]!.named !== undefined ? 0 : 1;
}

/// The width the line needs at `level`.
export function summaryLevelWidth(widths: SummaryWidths, level: number): number {
  const { kinds } = widths;
  if (kinds.length === 0) return 0;
  if (level < COUNT) {
    const form = FORMS[level] as "named" | "long" | "short";
    const sum = kinds.reduce((total, kind) => total + (kind[form] ?? kind.long), 0);
    return sum + widths.separator * (kinds.length - 1);
  }
  const folded = level - COUNT;
  const shown = kinds.length - folded;
  const sum = kinds.slice(0, shown).reduce((total, kind) => total + kind.count, 0);
  return sum + widths.gap * (shown - 1) + (folded > 0 ? widths.gap + widths.more : 0);
}

export function summaryLevelStep(widths: SummaryWidths, level: number): SummaryStep {
  if (level < COUNT) return { form: FORMS[level]!, shown: widths.kinds.length };
  return { form: "count", shown: widths.kinds.length - (level - COUNT) };
}

/// The richest level that fits `available`; an unmeasured box (0 or less) takes the richest.
export function fitSummaryLevel(widths: SummaryWidths, available: number): number {
  return available <= 0 ? firstLevel(widths) : fitMeasured(widths, available);
}

function fitMeasured(widths: SummaryWidths, available: number): number {
  const first = firstLevel(widths);
  const last = lastLevel(widths);
  for (let level = first; level < last; level += 1) {
    if (summaryLevelWidth(widths, level) <= available) return level;
  }
  return last;
}

/// The next level from `previous`: it degrades as soon as `previous` no longer fits, and grows only
/// when the richer level fits with `slack` to spare.
export function nextSummaryLevel(
  widths: SummaryWidths,
  available: number,
  previous: number | undefined,
  slack = SUMMARY_HYSTERESIS_PX,
): number {
  if (previous === undefined || available <= 0) return fitSummaryLevel(widths, available);
  const first = firstLevel(widths);
  const last = lastLevel(widths);
  const held = Math.min(Math.max(previous, first), last);
  const grown = fitMeasured(widths, available - slack);
  if (grown < held) return grown;
  if (held === last || summaryLevelWidth(widths, held) <= available) return held;
  return fitMeasured(widths, available);
}

/// Widths in, step out: the step a box of `available` px draws, `previous` its last level.
export function summaryStep(
  widths: SummaryWidths,
  available: number,
  previous?: number,
): { level: number; step: SummaryStep } {
  const level = nextSummaryLevel(widths, available, previous);
  return { level, step: summaryLevelStep(widths, level) };
}
