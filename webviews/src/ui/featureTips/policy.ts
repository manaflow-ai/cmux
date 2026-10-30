// When a feature tip may show (leo-workspace design/feature-tips.md, "Placement rules"). Pure: the
// host (FeatureTipHost.tsx) reads the moment and asks; the tests hold each rule.
//
// - Never on launch over work: a page shows nothing in its first TIP_SETTLE_MS, and only after
//   TIP_IDLE_MS with no key, press or scroll.
// - Never while an agent streams or the person types (a draft in the composer counts as typing).
// - Never over a menu, popover or dialog, nor in a page that is hidden or not focused.
// - Never without its control on screen: a tip points at the control, so no control, no tip.
// - At most one tip at a time, and one per app launch: the first tip a launch shows is its only one.
// - A tip closed with its X, or whose feature the person used, never shows again; nor one shown on
//   TIP_MAX_LAUNCHES launches without either (it was seen and passed over).
// - The Settings toggle (updates.showFeatureTips) turns every tip off.

/** A page shows no tip until it has been open this long. */
export const TIP_SETTLE_MS = 30_000;
/** ...and the person has not pressed a key, clicked or scrolled for this long. */
export const TIP_IDLE_MS = 8_000;
/** A tip shown on this many launches without its X or a use is retired. */
export const TIP_MAX_LAUNCHES = 3;

/** What the app keeps for one tip: closed with its X, its feature used, or shown on N launches. */
export type TipRecord = "closed" | "used" | `shown:${number}`;
export type TipRecords = Readonly<Record<string, string>>;

/** One tip, derived from its What's New highlight (`tip:` line; tips.generated.json). */
export interface FeatureTipEntry {
  /** The highlight's id. */
  id: string;
  /** The control it points at (the page's anchor table). */
  anchor: string;
  title: string;
  body: string;
}

export interface TipMoment {
  /** The Settings toggle. */
  enabled: boolean;
  /** The app keeps tip records (an older app does not: no tip, since none could stay dismissed). */
  hostReady: boolean;
  streaming: boolean;
  typing: boolean;
  pageAgeMs: number;
  idleMs: number;
  overlayOpen: boolean;
  focused: boolean;
  /** This launch's one tip already went to a page (the app's claim, store.ts), or is being claimed. */
  spent: boolean;
}

export type TipBlock =
  | "off"
  | "no-host"
  | "spent"
  | "streaming"
  | "typing"
  | "settling"
  | "busy"
  | "overlay"
  | "unfocused"
  | "no-anchor"
  | "done";

/** How many launches a record says the tip was shown on. */
export function shownLaunches(record: string | undefined): number {
  const match = /^shown:(\d+)$/.exec(record ?? "");
  return match ? Number(match[1]) : 0;
}

/** Whether a tip never shows again: closed, used, or passed over TIP_MAX_LAUNCHES times. */
export function isDone(record: string | undefined): boolean {
  return record === "closed" || record === "used" || shownLaunches(record) >= TIP_MAX_LAUNCHES;
}

/** The record to keep when a tip shows on one more launch. */
export function shownRecord(record: string | undefined): TipRecord {
  return `shown:${shownLaunches(record) + 1}`;
}

/** Why no tip may show now, before looking at any one tip (null: the moment allows one). */
export function momentBlock(moment: TipMoment): TipBlock | null {
  if (!moment.enabled) return "off";
  if (!moment.hostReady) return "no-host";
  if (moment.spent) return "spent";
  if (moment.streaming) return "streaming";
  if (moment.typing) return "typing";
  if (moment.pageAgeMs < TIP_SETTLE_MS) return "settling";
  if (moment.idleMs < TIP_IDLE_MS) return "busy";
  if (moment.overlayOpen) return "overlay";
  if (!moment.focused) return "unfocused";
  return null;
}

/** Whether the block ends on its own with time (the host waits), not on an event. */
export function waitsForTime(block: TipBlock): boolean {
  return block === "settling" || block === "busy";
}

/** How long until the time blocks of `moment` are over (0: none). */
export function waitMs(moment: TipMoment): number {
  return Math.max(0, TIP_SETTLE_MS - moment.pageAgeMs, TIP_IDLE_MS - moment.idleMs);
}

/** The tip to show now, or why none: the first tip not done whose control is on screen. */
export function pickTip(
  moment: TipMoment,
  tips: readonly FeatureTipEntry[],
  records: TipRecords,
  anchorVisible: (anchor: string) => boolean,
): { tip: FeatureTipEntry } | { block: TipBlock } {
  const block = momentBlock(moment);
  if (block) return { block };
  const open = tips.filter((tip) => !isDone(records[tip.id]));
  if (open.length === 0) return { block: "done" };
  const tip = open.find((entry) => anchorVisible(entry.anchor));
  return tip ? { tip } : { block: "no-anchor" };
}

/** Whether every tip is done, so the host stops listening for good. */
export function allDone(tips: readonly FeatureTipEntry[], records: TipRecords): boolean {
  return tips.every((tip) => isDone(records[tip.id]));
}
