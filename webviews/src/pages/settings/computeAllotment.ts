// l10n-allow-file: the Compute card's English copy until the backend serves it localized.
// Settings > Team > Compute's view-model: everything the card draws, derived from the backend's
// `AllotmentView` (cloud.allotment.get) with no React. The proposal sentence, the figure under each
// position of the dial, the member rows (sorted, with their notes), the meter's segments and ticks
// and the inbox's reason cards all come from here, so the three layouts are dumb renderers and the
// backend can later serve this shape itself. Money is micros (millionths of a US dollar); it is
// worded with the Cloud page's spend-cap formatter (pages/cloud/spendCap.ts).
import { day, usd } from "../cloud/spendCap";
import { intl } from "../../ui/intl";
import type { AllotmentPosition, AllotmentReason, AllotmentView, ChiefTier, MemberUse, PersonHoldSeconds } from "./ops";

/** The Labs switch that mounts the card in Settings > Cloud (schemas/settings/source/labs.json);
 * off, the card draws nothing and reads nothing. */
export const TEAM_COMPUTE_LAB = "labs.teamCompute";

/** Pooled usage every seat includes each month. */
export const SEAT_MICROS = 25_000_000;
/** One step of extra commit, and what it costs a month (20% off). */
export const COMMIT_STEP_MICROS = 25_000_000;
export const STEP_PRICE_MICROS = 20_000_000;
const DAYS = 14;

export const POSITIONS: readonly AllotmentPosition[] = ["down", "hold", "up"];

/** The holds a team can choose for its people's machines; null is none. */
export const HOLD_CHOICES: readonly (PersonHoldSeconds | null)[] = [null, 300, 900, 1800];
/** What the one-switch control turns on. */
export const HOLD_SWITCH_SECONDS: PersonHoldSeconds = 1800;

export type HoldOption = { seconds: PersonHoldSeconds | null; label: string; selected: boolean };

/** The team's hold as the card draws it: the choice, each option and one plain line saying what it does. */
export function holdModel(view: AllotmentView): ComputeModel["hold"] {
  const set = view.allotment?.person_hold_seconds;
  const seconds = HOLD_CHOICES.find((choice) => choice !== null && choice === set) ?? null;
  return {
    seconds,
    options: HOLD_CHOICES.map((choice) => ({
      seconds: choice,
      label: choice === null ? "Off" : `${choice / 60} min`,
      selected: choice === seconds,
    })),
    line:
      seconds === null
        ? "Machines pause when idle and wake on the next message."
        : `A machine someone is chatting on stays ready for ${seconds / 60} minutes after each reply. Agents' machines still pause when idle.`,
  };
}

/** "$40", or "$12.50" when there are cents; the spend cap's currency formatting. */
export function money(micros: number, language: string): string {
  const cents = Math.round(micros / 10_000);
  if (cents % 100 !== 0) return usd(cents / 100, language);
  return intl
    .NumberFormat(language, { style: "currency", currency: "USD", maximumFractionDigits: 0, minimumFractionDigits: 0 })
    .format(cents / 100);
}

/** The commit an action sets: the proposal's `to_commit_micros` in its own direction, one $25 step
 * the other way (never below zero), the current commit for hold. The mock backend applies the same. */
export function commitFor(view: AllotmentView, action: AllotmentPosition): number {
  const commit = view.allotment?.commit_micros ?? 0;
  if (action === "hold") return commit;
  if (action === view.decision.position) return view.decision.to_commit_micros;
  return action === "up" ? commit + COMMIT_STEP_MICROS : Math.max(0, commit - COMMIT_STEP_MICROS);
}

/** What `target` costs a month over today's commit (negative: what it saves). */
export function monthlyChange(view: AllotmentView, target: number): number {
  const commit = view.allotment?.commit_micros ?? 0;
  return ((target - commit) / COMMIT_STEP_MICROS) * STEP_PRICE_MICROS;
}

export type DialOption = {
  position: AllotmentPosition;
  label: string;
  /** The allotment after this choice, a month. */
  allotMicros: number;
  /** "$350 a month" */
  figure: string;
  /** "costs $40 a month", "saves $40 a month", "no change" */
  change: string;
  proposed: boolean;
  /** Nothing to apply (down at no commit). */
  disabled: boolean;
};

export type MemberRow = {
  /** The member id (the row's key). */
  member: string;
  /** What the card prints: the view's display name, else the id. */
  name: string;
  /** "11 of 14 days", ", Chief Plus" when the tier is not standard. */
  detail: string;
  month: string;
  /** This month's use as a share of the allotment, "32%". */
  share: string;
  note: string;
};

export type MeterSegment = { member: string; name: string; fraction: number; month: string };

export type ReasonCard = {
  key: string;
  text: string;
  /** The position Accept applies; null when the set op has no gesture for it yet (a tier change). */
  accept: AllotmentPosition | null;
};

export type ComputeModel = {
  empty: boolean;
  sentence: string;
  proposed: AllotmentPosition;
  auto: boolean;
  /** The dial can apply nothing (the empty team). */
  locked: boolean;
  options: DialOption[];
  rows: MemberRow[];
  spares: { member: string; detail: string; month: string; note: string };
  /** "Holding at $300, Auto off" */
  holdLine: string;
  hardCap: string;
  /** The team's hold for its people's machines (drawn only where a layout asks for the control). */
  hold: { seconds: PersonHoldSeconds | null; options: HoldOption[]; line: string };
  reasons: ReasonCard[];
  meter: {
    segments: MeterSegment[];
    /** Where the allotment and the hard cap sit on the bar, 0 to 1. */
    allot: number;
    cap: number | null;
    allotLabel: string;
    capLabel: string | null;
  };
};

const TIER_NAMES: Record<ChiefTier, string> = { standard: "Standard", plus: "Chief Plus", max: "Chief Max" };
const LABELS: Record<AllotmentPosition, string> = { down: "Scale down", hold: "Hold", up: "Scale up" };

const times = (count: number) => (count === 1 ? "once" : `${count} times`);

/** The members in the card's order: most used in the last 14 days first, then this month, then by name. */
export function sortedMembers(members: readonly MemberUse[]): MemberUse[] {
  return [...members].sort(
    (a, b) => b.usd14_micros - a.usd14_micros || b.month_micros - a.month_micros || a.member.localeCompare(b.member),
  );
}

/** The name a member is printed with: the view's display name, else the id. */
export function memberName(view: AllotmentView, member: string): string {
  return view.names?.[member] || member;
}

/** No one used Cloud at all. */
export function isEmpty(view: AllotmentView): boolean {
  return view.decision.members.every((row) => row.month_micros === 0 && row.usd14_micros === 0);
}

function changeText(micros: number, language: string, auto: boolean, position: AllotmentPosition): string {
  if (micros === 0) return "no change";
  const amount = money(Math.abs(micros), language);
  if (auto)
    return position === "up"
      ? `Auto scales up, adding ${amount} a month`
      : `Auto scales down, saving ${amount} a month`;
  return micros > 0 ? `costs ${amount} a month` : `saves ${amount} a month`;
}

/** What a reason says on its own, without the cost ("Austin passed the allotment 4 times"). */
function cause(reason: AllotmentReason, seats: number, language: string, name: (member: string) => string): string {
  switch (reason.kind) {
    case "unused":
      return reason.members.length === 1
        ? `${name(reason.members[0])} used nothing in ${DAYS} days`
        : `${reason.members.length} of ${seats} members used nothing in ${DAYS} days`;
    case "over":
      return `${name(reason.member)} passed the allotment ${times(reason.count)}`;
    case "runaway":
      return `${name(reason.member)} is using ${money(reason.rate_micros_h, language)} an hour`;
    case "tier":
      return `${name(reason.member)} could use ${TIER_NAMES[reason.to]}: +${money(reason.costs_micros, language)} a month`;
  }
}

const drives = (reason: AllotmentReason, position: AllotmentPosition) =>
  position === "down"
    ? reason.kind === "unused"
    : position === "up" && (reason.kind === "over" || reason.kind === "runaway");

const acceptOf = (reason: AllotmentReason): AllotmentPosition | null =>
  reason.kind === "unused" ? "down" : reason.kind === "tier" ? null : "up";

/** The one proposal sentence. */
export function proposalSentence(view: AllotmentView, language: string): string {
  const { decision, allotment } = view;
  const seats = decision.members.length;
  if (isEmpty(view))
    return `No one has used Cloud yet. ${seats} seats include ${money(seats * SEAT_MICROS, language)} a month. Nothing to decide.`;
  const snoozed = allotment?.snoozed_until != null && allotment.snoozed_until > view.as_of;
  if (decision.position === "hold")
    return snoozed
      ? `Holding at ${money(decision.allot_micros, language)} until ${day(allotment.snoozed_until!, language)}. Nothing to decide.`
      : "Usage fits the allotment. Nothing to decide.";
  const reason = decision.reasons.find((candidate) => drives(candidate, decision.position));
  const why = reason
    ? cause(reason, seats, language, (member) => memberName(view, member))
    : `This month is on track for ${money(decision.forecast_micros, language)} of ${money(decision.allot_micros, language)}`;
  const auto = allotment?.mode === "auto";
  const change = monthlyChange(view, decision.to_commit_micros);
  const what = auto
    ? changeText(change, language, true, decision.position)
    : `scaling ${decision.position} ${changeText(change, language, false, decision.position)}`;
  return `${why}: ${what}.`;
}

function rowNote(row: MemberUse, reasons: readonly AllotmentReason[], language: string): string {
  const notes: string[] = [];
  if (row.over_share14 > 0) notes.push(`passed allotment ${row.over_share14}x`);
  for (const reason of reasons) {
    if (reason.kind === "runaway" && reason.member === row.member)
      notes.push(`${money(reason.rate_micros_h, language)} an hour now`);
    if (reason.kind === "tier" && reason.member === row.member)
      notes.push(`could use ${TIER_NAMES[reason.to]}: +${money(reason.costs_micros, language)}`);
  }
  if (row.usd14_micros === 0) notes.push("unused");
  return notes.join(", ");
}

const percent = (fraction: number) => `${Math.round(fraction * 100)}%`;

/** Everything the card draws for `view`. */
export function computeModel(view: AllotmentView, language: string): ComputeModel {
  const { decision, allotment } = view;
  const empty = isEmpty(view);
  const commit = allotment?.commit_micros ?? 0;
  const auto = allotment?.mode === "auto";
  const proposed: AllotmentPosition = empty ? "hold" : decision.position;
  const options = POSITIONS.map((position): DialOption => {
    const target = commitFor(view, position);
    const allotMicros = decision.allot_micros - commit + target;
    return {
      position,
      label: LABELS[position],
      allotMicros,
      figure: `${money(allotMicros, language)} a month`,
      change: changeText(monthlyChange(view, target), language, false, position),
      proposed: position === proposed,
      disabled: empty || (position !== "hold" && target === commit),
    };
  });
  const members = sortedMembers(decision.members);
  const allot = Math.max(decision.allot_micros, 1);
  const name = (member: string) => memberName(view, member);
  const rows = members.map((row): MemberRow => ({
    member: row.member,
    name: name(row.member),
    detail: `${row.active_days14} of ${DAYS} days${row.tier === "standard" ? "" : `, ${TIER_NAMES[row.tier]}`}`,
    month: money(row.month_micros, language),
    share: percent(row.month_micros / allot),
    note: rowNote(row, decision.reasons, language),
  }));
  const used = members.reduce((sum, row) => sum + row.month_micros, 0);
  const cap = view.hard_cap_micros;
  const scale = Math.max(decision.allot_micros, cap ?? 0, used, 1);
  return {
    empty,
    sentence: proposalSentence(view, language),
    proposed,
    auto,
    locked: empty,
    options,
    rows,
    spares: {
      member: "Warm spares",
      detail: "ours",
      month: money(0, language),
      note: "not counted against the allotment",
    },
    holdLine: `Holding at ${money(decision.allot_micros, language)}, Auto ${auto ? "on" : "off"}`,
    hardCap:
      cap === null
        ? "No hard cap. Set one under Spending cap on the Cloud page."
        : `Hard cap: ${money(cap, language)} a month. Change it under Spending cap on the Cloud page.`,
    hold: holdModel(view),
    reasons: decision.reasons.map((reason, index): ReasonCard => {
      const accept = acceptOf(reason);
      const change = accept ? changeText(monthlyChange(view, commitFor(view, accept)), language, false, accept) : "";
      const then = accept ? ` Scaling ${accept} ${change}.` : "";
      return {
        key: `${reason.kind}-${index}`,
        text: `${cause(reason, members.length, language, name)}.${then}`,
        accept,
      };
    }),
    meter: {
      segments: members
        .filter((row) => row.month_micros > 0)
        .map((row) => ({
          member: row.member,
          name: name(row.member),
          fraction: row.month_micros / scale,
          month: money(row.month_micros, language),
        })),
      allot: decision.allot_micros / scale,
      cap: cap === null ? null : cap / scale,
      allotLabel: `Allotment ${money(decision.allot_micros, language)}`,
      capLabel: cap === null ? null : `Hard cap ${money(cap, language)}`,
    },
  };
}
