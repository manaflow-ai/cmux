// l10n-allow-file: the Spending card's English copy until the backend serves it localized.
// Settings > Cloud > Spending (RFD 0080 "Spend controls"): what happens past the plan's own Cloud pool. Two
// settings, the overage limit (`spendCapUsd`, off by default) and the size above which an agent asks first, and
// the team's read of that limit (`cloud.plan.get`'s `spend_cap`) worded as one meter and one banner.
//
// The backend decides every state: "near" (the 80% banner) and "at_cap" (cloud agents paused by `paused_by:
// spend_cap`) come from `spend_cap.state`; this module computes no threshold. It only parses the dollar field
// and words what it was given. SpendingCard.tsx draws the result and nothing else.
//
// No write path exists yet: no typed client call sets `spendCapUsd` (cmux-cloud-wire has the read and the
// `cloud.spend_cap.reached` refusal only). The card hands its changes to an `onChange` callback; the write is the
// next PR, a Rust op beside the other cloud settings that the settings store calls.
import { type SpendCap, day, usd } from "../cloud/spendCap";

/** A computer's size, as the cloud sizes it (RFD 0080's ComputerStatus `shape`). */
export type Shape = { vcpu: number; memory_gib: number };

/** The two Spending settings. `overage_limit_usd: null` is overage off: past the plan's pool, cloud agents pause. */
export type SpendingSettings = { overage_limit_usd: number | null; ask_above: Shape };

// PLACEHOLDER defaults: RFD 0080's assumption A ("overage off, ask above 8 vCPU / 16 GB", half the seat's awake
// pool in RFD 0071), pending cmuxterm-hq#19567 (pricing and defaults) and lane B (which pool governs). Nothing here
// picks a price; change these only from those decisions.
export const DEFAULT_SPENDING: SpendingSettings = { overage_limit_usd: null, ask_above: { vcpu: 8, memory_gib: 16 } };

// PLACEHOLDER shapes for the "ask before above" picker, the sizes RFD 0071 names; the server's shape list replaces
// these once it serves one.
export const ASK_ABOVE_SHAPES: readonly Shape[] = [
  { vcpu: 4, memory_gib: 8 },
  { vcpu: 8, memory_gib: 16 },
  { vcpu: 16, memory_gib: 32 },
  { vcpu: 32, memory_gib: 64 },
];

/** "8 vCPU · 16 GB". */
export function shapeLabel(shape: Shape): string {
  return `${shape.vcpu} vCPU · ${shape.memory_gib} GB`;
}

/** A shape's key for a select: "8x16". */
export function shapeKey(shape: Shape): string {
  return `${shape.vcpu}x${shape.memory_gib}`;
}

export function parseShapeKey(key: string): Shape | undefined {
  const match = /^(\d+)x(\d+)$/.exec(key);
  if (!match) return undefined;
  const vcpu = Number(match[1]);
  const memory = Number(match[2]);
  return vcpu > 0 && memory > 0 ? { vcpu, memory_gib: memory } : undefined;
}

export type LimitParse = { ok: true; usd: number | null } | { ok: false; error: string };

/**
 * The dollar field as typed: empty is off (`null`); otherwise a positive amount in dollars and cents. A leading
 * "$", spaces and thousands commas are accepted; anything else, zero, a negative or more than two decimals is
 * refused with a sentence that says what to type.
 */
export function parseLimitUsd(text: string): LimitParse {
  const trimmed = text
    .trim()
    .replace(/^\$\s*/, "")
    .replace(/,/g, "")
    .trim();
  if (trimmed === "") return { ok: true, usd: null };
  if (!/^\d+(\.\d{1,2})?$|^\.\d{1,2}$/.test(trimmed)) {
    return trimmed.startsWith("-")
      ? { ok: false, error: "Enter an amount above $0, or leave it empty to turn overage off." }
      : { ok: false, error: "Enter dollars and cents, like 40 or 40.50." };
  }
  const value = Number(trimmed);
  if (!Number.isFinite(value) || value <= 0)
    return { ok: false, error: "Enter an amount above $0, or leave it empty to turn overage off." };
  return { ok: true, usd: value };
}

/** The field's text for a saved limit: "40" or "40.50"; empty when off. */
export function limitText(value: number | null): string {
  if (value === null) return "";
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}

export type SpendingBanner =
  | { kind: "near"; title: string; message: string }
  | { kind: "paused"; title: string; message: string }
  /** Overage off and the plan's pool used up: cloud agents paused; the action turns overage on. */
  | { kind: "pool_spent"; title: string; message: string };

export type SpendingMeter = { fraction: number; label: string };

export type SpendingModel = {
  overageOn: boolean;
  limitText: string;
  /** Under the overage row: what the limit does, in one sentence. */
  overageHelp: string;
  askAbove: string;
  askOptions: { value: string; label: string }[];
  askHelp: string;
  /** Spent of the limit this period, only with overage on and a read that has both amounts. */
  meter: SpendingMeter | null;
  banner: SpendingBanner | null;
};

const num = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;

const KEEP_LOCAL = "Agents on This Mac keep running.";

/** The card's view of `settings` and the team's last cap read. */
export function spendingModel(
  settings: SpendingSettings,
  read: SpendCap | null | undefined,
  language: string,
): SpendingModel {
  const on = settings.overage_limit_usd !== null;
  const askOptions = ASK_ABOVE_SHAPES.map((shape) => ({ value: shapeKey(shape), label: shapeLabel(shape) }));
  if (!askOptions.some((option) => option.value === shapeKey(settings.ask_above)))
    askOptions.push({ value: shapeKey(settings.ask_above), label: shapeLabel(settings.ask_above) });
  const model: SpendingModel = {
    overageOn: on,
    limitText: limitText(settings.overage_limit_usd),
    overageHelp: on
      ? "Past the plan's pool, Cloud keeps going and bills overage up to this amount a month. At the limit, cloud agents pause, never stop."
      : "Past the plan's pool, cloud agents pause, never stop: memory and processes are kept. Nothing is billed past the plan.",
    askAbove: shapeKey(settings.ask_above),
    askOptions,
    askHelp: "A bigger agent asks once first, and can use a build machine for that command instead.",
    meter: null,
    banner: null,
  };
  if (!read) return model;
  const periodEndOff = num(read.period_end);
  if (!on) {
    if (read.state === "at_cap" || num(read.paused_at) !== undefined)
      model.banner = {
        kind: "pool_spent",
        title: "The plan's Cloud pool is used up",
        message: `Cloud agents are paused, not stopped: their memory and processes are kept. Turn on overage to keep them going. ${KEEP_LOCAL}${periodEndOff === undefined ? "" : ` The pool resets ${day(periodEndOff, language)}.`}`,
      };
    return model;
  }
  const spent = num(read.spent_usd);
  const cap = num(read.cap_usd) ?? settings.overage_limit_usd ?? undefined;
  const periodEnd = num(read.period_end);
  const resets = periodEnd === undefined ? "" : ` It resets ${day(periodEnd, language)}.`;
  if (spent !== undefined && cap !== undefined && cap > 0)
    model.meter = {
      fraction: Math.min(1, Math.max(0, spent / cap)),
      label: `${usd(spent, language)} of ${usd(cap, language)} this month`,
    };
  if (read.state === "at_cap" || num(read.paused_at) !== undefined) {
    model.banner = {
      kind: "paused",
      title: "Paused at your overage limit",
      message: `Cloud agents are paused, not stopped: their memory and processes are kept. ${KEEP_LOCAL}${resets}`,
    };
  } else if (read.state === "near" && spent !== undefined && cap !== undefined && cap > 0) {
    const percent = Math.floor((spent / cap) * 100);
    model.banner = {
      kind: "near",
      title: `${percent}% of this month's overage limit used`,
      message: `${usd(spent, language)} of ${usd(cap, language)}. At the limit, cloud agents pause and keep their memory. ${KEEP_LOCAL}`,
    };
  }
  return model;
}
