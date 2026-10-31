// When a feature tip may show (leo-workspace design/feature-tips.md, "Placement rules"). Pure: the
// host (FeatureTipHost.tsx) reads the moment and asks; the tests hold each rule.
//
// - Never on launch over work: a page shows nothing in its first TIP_SETTLE_MS, and only after
//   TIP_IDLE_MS with no key, press or scroll.
// - Never while an agent streams or the person types (a draft in the composer counts as typing).
// - Never over a menu, popover or dialog, nor in a page that is hidden or not focused.
// - Never without its control on screen: a tip points at the control, so no control, no tip.
// - Install-level (Leo, 2026-10-30: "no this should be very very infrequent like app installation
//   level frequent and if they havent used the browser"): each tip shows at most once per install,
//   never once its feature was used, and at most one tip every 14 days. The app decides that
//   (`TipHost.claim`, Swift AgentPaneFeatureTipRecords); a page only asks at a right moment.
// - A tip with any record (shown, closed with its X, used) never shows again.
// - The Settings toggle (updates.showFeatureTips) turns every tip off.

/** A page shows no tip until it has been open this long. */
export const TIP_SETTLE_MS = 30_000;
/** ...and the person has not pressed a key, clicked or scrolled for this long. */
export const TIP_IDLE_MS = 8_000;
/** What a page keeps for one tip: closed with its X, or its feature used. The app records `shown`
    itself when it grants a tip. */
export type TipRecord = "closed" | "used";
export type TipRecords = Readonly<Record<string, string>>;

/** What the app keeps for this install: each tip's record, and the features the person used. */
export interface TipState {
  records: TipRecords;
  used: ReadonlySet<string>;
}

/** One tip, derived from its What's New highlight (`tip:` line; tips.generated.json). */
export interface FeatureTipEntry {
  /** The highlight's id. */
  id: string;
  /** The control it points at (the page's anchor table). */
  anchor: string;
  title: string;
  body: string;
  /** The feature it is about (its control's, the anchor table): a use of it means no tip. */
  feature?: string;
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
  /** The app was asked for a tip from this page, or said no: this page asks no more. */
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

/** Whether a tip never shows: it has a record (shown once, closed, used), or its feature was used. */
export function isDone(tip: FeatureTipEntry, state: TipState): boolean {
  return state.records[tip.id] !== undefined || (tip.feature !== undefined && state.used.has(tip.feature));
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
  state: TipState,
  anchorVisible: (anchor: string) => boolean,
): { tip: FeatureTipEntry } | { block: TipBlock } {
  const block = momentBlock(moment);
  if (block) return { block };
  const open = tips.filter((tip) => !isDone(tip, state));
  if (open.length === 0) return { block: "done" };
  const tip = open.find((entry) => anchorVisible(entry.anchor));
  return tip ? { tip } : { block: "no-anchor" };
}

/** Whether every tip is done, so the host stops listening for good. */
export function allDone(tips: readonly FeatureTipEntry[], state: TipState): boolean {
  return tips.every((tip) => isDone(tip, state));
}
