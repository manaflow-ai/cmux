// l10n-allow-file: gallery design fixtures for the native agent badges (experiments.agentBadges), not shipped UI.
// The pure rules of the agent badges mock (AgentBadges.tsx): what a tab's count reads, what a row's
// status pill reads, and what each reserved slot is sized by. A slot is sized by every text it can
// ever show, stacked invisibly in one grid cell, so the slot's width is the same for every state and
// nothing beside it (the tab title, the row title) moves when a count or status changes.

/** A row's agent state, as the sidebar knows it. */
export type AgentStatus = "idle" | "running" | "approval" | "done";

/** The badge look: the `experiments.agentBadges` arms, plus a compact count dot alternative. */
export type BadgeLook = "off" | "pills" | "beam" | "dot-count";

/** Counts past this read as "99+". */
export const COUNT_CAP = 99;

/** The count pill's text: nothing at 0, the number up to the cap, then "99+". */
export function formatCount(count: number): string {
  if (!Number.isFinite(count) || count <= 0) return "";
  const whole = Math.floor(count);
  return whole > COUNT_CAP ? `${COUNT_CAP}+` : String(whole);
}

/** The status pill's words (Leo, 2026-11-19: "Running, Needs approval, Done"); idle draws no pill. */
export const STATUS_LABEL: Record<AgentStatus, string> = {
  idle: "",
  running: "Running",
  approval: "Needs approval",
  done: "Done",
};

/** Words for assistive tech, so the row's state is never only a color or a pill. */
export const STATUS_SPOKEN: Record<AgentStatus, string> = {
  idle: "",
  running: ", working",
  approval: ", waiting on your approval",
  done: ", finished, unread",
};

const pillTexts = (Object.keys(STATUS_LABEL) as AgentStatus[]).map((status) => STATUS_LABEL[status]).filter(Boolean);

/** A reserved slot: the text it shows now, and the texts that size it (the same for every state). */
export interface Slot {
  text: string;
  sizers: readonly string[];
}

/** The widest count a tab ever shows: the slot is this wide at 0 and at 120 alike. */
export const COUNT_SIZERS: readonly string[] = Object.freeze([`${COUNT_CAP}+`]);
/** Every status pill's words: the row's pill column is as wide as the widest. */
export const PILL_SIZERS: readonly string[] = Object.freeze(pillTexts);

/** The tab's count slot for `count`: its text changes, its sizers never do. */
export function countSlot(count: number): Slot {
  return { text: formatCount(count), sizers: COUNT_SIZERS };
}

/** The row's status pill slot for `status`: its text changes, its sizers never do. */
export function pillSlot(status: AgentStatus): Slot {
  return { text: STATUS_LABEL[status], sizers: PILL_SIZERS };
}

/** Whether a row draws the edge beam: only the beam look, and only while its agent runs. */
export function showsBeam(look: BadgeLook, status: AgentStatus): boolean {
  return look === "beam" && status === "running";
}

/** The count a tab carries: unread agent messages plus pending approvals. */
export function tabCount(unread: number, approvals: number): number {
  return Math.max(0, unread) + Math.max(0, approvals);
}
