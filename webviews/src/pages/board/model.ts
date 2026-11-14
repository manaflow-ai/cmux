// Pure logic of the team board: the three platform answers joined into one row per machine, the
// totals, the order and the filter. No DOM, no clock of its own (the caller passes `now`).
//
// The page trusts no number: a cost that is missing, negative, non-finite or a string counts as
// unknown, is shown as a dash and is left out of the totals, which then say how many were unknown.
import type {
  BoardSnapshot,
  MachineAuditRow,
  MachineOrigin,
  MachineSession,
  MachineState,
  TeamMachine,
  TeamMember,
} from "./types";

/** Who a row's owner is, as far as the answers tell. */
export type Owner =
  | { kind: "self"; user: string }
  | { kind: "member"; user: string; name: string }
  /** A user id the team's member list does not hold (left the team, or no member list yet). */
  | { kind: "unknown"; user: string }
  | { kind: "none" };

export interface BoardRow {
  id: string;
  /** What a person reads as the machine's name: its name, else its id. */
  title: string;
  state: MachineState;
  owner: Owner;
  /** Who or what started it, when the platform records it. */
  origin: MachineOrigin | null;
  /** Total cost so far in USD, or null when the answer gave no sane number. */
  costUsd: number | null;
  /** The running rate in USD per hour, or null. */
  hourlyUsd: number | null;
  /** When the current run started (ms), for a cost that keeps growing. */
  runningSince: number | null;
  /** People on it now (attached clients). */
  present: number;
  /** The newest audit action on it: what was last done to it, by whom. */
  last: { action: string; actor: string; actorKind: "person" | "agent"; at: number; result: string } | null;
  /** Its agent sessions, waiting ones first. */
  sessions: MachineSession[];
  /** At least one agent waits on a person. */
  waiting: boolean;
  error: string | null;
  createdAt: number;
}

export interface BoardTotals {
  machines: number;
  running: number;
  waiting: number;
  unowned: number;
  /** Sum of the known costs. */
  costUsd: number;
  /** Machines whose cost the answers did not give sanely. */
  unknownCost: number;
  /** Sum of the running machines' known hourly rates. */
  hourlyUsd: number;
}

export type BoardFilter = "all" | "running" | "waiting" | "unowned";

/** A cost the page can show: finite and not negative. */
export function saneUsd(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}

const RUNNING: ReadonlySet<MachineState> = new Set(["running", "starting", "waking"]);

export function isRunning(state: MachineState): boolean {
  return RUNNING.has(state);
}

export function ownerOf(
  creator: string | undefined,
  members: ReadonlyMap<string, TeamMember>,
  self?: string | null,
): Owner {
  const user = typeof creator === "string" ? creator.trim() : "";
  if (!user) return { kind: "none" };
  if (self && user === self) return { kind: "self", user };
  const member = members.get(user);
  if (member) return { kind: "member", user, name: member.name?.trim() || member.email?.trim() || user };
  return { kind: "unknown", user };
}

/** The newest audit row per machine id (the audit answer is newest first, but the page does not rely on it). */
export function lastActions(audit: readonly MachineAuditRow[] | null | undefined): Map<string, MachineAuditRow> {
  const last = new Map<string, MachineAuditRow>();
  for (const row of audit ?? []) {
    if (row.target !== "machine" || typeof row.targetId !== "string") continue;
    const seen = last.get(row.targetId);
    if (!seen || row.at > seen.at) last.set(row.targetId, row);
  }
  return last;
}

export interface JoinContext {
  members: ReadonlyMap<string, TeamMember>;
  self: string | null;
  /** Usage cost by machine id, used when the list answer has no cost. */
  usageCost: ReadonlyMap<string, number>;
  last: Map<string, MachineAuditRow>;
  sessions: Record<string, MachineSession[]>;
}

export function contextOf(snapshot: BoardSnapshot): JoinContext {
  const members = new Map<string, TeamMember>();
  for (const member of snapshot.members ?? []) if (member?.user) members.set(member.user, member);
  const usageCost = new Map<string, number>();
  for (const row of snapshot.usage?.byMachine ?? []) {
    const cost = saneUsd(row.costUsd);
    if (row.machineId && cost !== null) usageCost.set(row.machineId, cost);
  }
  return {
    members,
    self: snapshot.self ?? null,
    usageCost,
    last: lastActions(snapshot.audit),
    sessions: { ...snapshot.sessions },
  };
}

const sessionRank = { waiting: 0, working: 1, idle: 2 } as const;

/** The fields of a row the audit and the sessions give (they change without the machine record). */
export function liveOf(id: string, context: JoinContext): Pick<BoardRow, "last" | "sessions" | "waiting"> {
  const last = context.last.get(id);
  const sessions = [...(context.sessions[id] ?? [])].sort(
    (a, b) => sessionRank[a.state] - sessionRank[b.state] || (a.waitingSince ?? 0) - (b.waitingSince ?? 0),
  );
  return {
    last: last
      ? { action: last.action, actor: last.actor, actorKind: last.actorKind, at: last.at, result: last.result }
      : null,
    sessions,
    waiting: sessions.some((session) => session.state === "waiting"),
  };
}

export function rowOf(machine: TeamMachine, context: JoinContext): BoardRow {
  const cost = machine.cost;
  const name = typeof machine.name === "string" ? machine.name.trim() : "";
  return {
    id: machine.id,
    title: name || machine.id,
    state: machine.state,
    owner: ownerOf(machine.creator, context.members, context.self),
    origin: machine.origin?.label ? machine.origin : null,
    costUsd: saneUsd(cost?.totalUsd) ?? context.usageCost.get(machine.id) ?? null,
    hourlyUsd: saneUsd(cost?.hourlyUsd),
    runningSince:
      typeof cost?.runningSince === "number" && Number.isFinite(cost.runningSince) ? cost.runningSince : null,
    present: Array.isArray(machine.present) ? machine.present.length : 0,
    ...liveOf(machine.id, context),
    error: machine.error?.message ?? null,
    createdAt: typeof machine.createdAt === "number" && Number.isFinite(machine.createdAt) ? machine.createdAt : 0,
  };
}

export function joinRows(snapshot: BoardSnapshot): BoardRow[] {
  const context = contextOf(snapshot);
  const seen = new Set<string>();
  const rows: BoardRow[] = [];
  for (const machine of snapshot.machines ?? []) {
    // A machine listed twice shows once: the first record.
    if (!machine?.id || seen.has(machine.id)) continue;
    seen.add(machine.id);
    rows.push(rowOf(machine, context));
  }
  return rows;
}

export function emptyTotals(): BoardTotals {
  return { machines: 0, running: 0, waiting: 0, unowned: 0, costUsd: 0, unknownCost: 0, hourlyUsd: 0 };
}

/** Adds (`sign` 1) or takes away (`sign` -1) one row's share, so a change costs O(1), not O(N). */
export function addToTotals(totals: BoardTotals, row: BoardRow, sign: 1 | -1): void {
  totals.machines += sign;
  const running = isRunning(row.state);
  if (running) totals.running += sign;
  if (row.waiting) totals.waiting += sign;
  if (isUnowned(row.owner)) totals.unowned += sign;
  if (row.costUsd === null) totals.unknownCost += sign;
  else totals.costUsd += sign * row.costUsd;
  if (running && row.hourlyUsd !== null) totals.hourlyUsd += sign * row.hourlyUsd;
}

export function isUnowned(owner: Owner): boolean {
  return owner.kind === "none" || owner.kind === "unknown";
}

const STATE_RANK: Record<MachineState, number> = {
  failed: 1,
  running: 2,
  starting: 2,
  waking: 2,
  paused: 3,
  stopped: 3,
  gone: 4,
};

/** A state the page does not know (a newer platform) sorts with the paused ones. */
const stateRank = (state: MachineState) => STATE_RANK[state] ?? 3;

/**
 * The board's order: machines waiting on a person first, then failed, running, paused; inside each,
 * the newest first. Every key is one that changes rarely (a cost tick never reorders the list).
 */
export function compareRows(a: BoardRow, b: BoardRow): number {
  return (
    Number(b.waiting) - Number(a.waiting) ||
    stateRank(a.state) - stateRank(b.state) ||
    b.createdAt - a.createdAt ||
    (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
  );
}

/** Whether an order key of the row changed (only then does the list re-sort). */
export function orderKeyChanged(a: BoardRow, b: BoardRow): boolean {
  return a.waiting !== b.waiting || stateRank(a.state) !== stateRank(b.state) || a.createdAt !== b.createdAt;
}

export function ownerText(owner: Owner): string {
  switch (owner.kind) {
    case "self":
    case "unknown":
      return owner.user;
    case "member":
      return owner.name;
    case "none":
      return "";
  }
}

/** Lowercased text a search matches: the title, id, owner and origin. */
export function searchText(row: BoardRow): string {
  return `${row.title} ${row.id} ${ownerText(row.owner)} ${row.origin?.label ?? ""}`.toLowerCase();
}

export function matches(row: BoardRow, filter: BoardFilter, query: string, text: string): boolean {
  switch (filter) {
    case "running":
      if (!isRunning(row.state)) return false;
      break;
    case "waiting":
      if (!row.waiting) return false;
      break;
    case "unowned":
      if (!isUnowned(row.owner)) return false;
      break;
    case "all":
      break;
  }
  return !query || text.includes(query);
}
