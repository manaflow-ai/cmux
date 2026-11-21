// The team board's wire shapes. The board is fed by three answers the platform already gives
// (cmux-platform src/api/Machines.ts; cmux-tui/crates/cmux-cloud-client/openapi.json):
//   GET /v1/machines        every machine of the team (TeamMachine)
//   GET /v1/machines/usage  cost and hours by creator, by machine and by who started it (MachineUsage)
//   GET /v1/machines/audit  the last 50 actions (MachineAuditRow)
// The host reads them and answers `cmux.board.snapshot` with all three untouched, plus the team's
// members when it knows them. The page joins them (model.ts); it never trusts a number to be sane.

export const BoardOps = {
  /** `{}` → BoardSnapshot. */
  snapshot: "cmux.board.snapshot",
  /** Event stream of BoardEvent, in order. */
  changes: "cmux.board.changes",
  /** `{machine}` → TeamMachine: pauses a running machine (the platform's `pause`). */
  stop: "cmux.board.stop",
  /** `{machine}` → `{opened: boolean}`: opens the machine in this app (the Cloud page's connect). */
  open: "cmux.board.open",
} as const;

export type MachineState = "starting" | "waking" | "running" | "paused" | "stopped" | "failed" | "gone";

/** A wire number the platform may send as a string for a non-finite value. */
export type WireNumber = number | "Infinity" | "-Infinity" | "NaN";

export interface MachineCost {
  currency?: "USD";
  estimated?: boolean;
  hourlyUsd?: number;
  idleHourlyUsd?: number;
  accruedUsd?: number;
  runningUsd?: number;
  totalUsd?: number;
  runningSince?: number | null;
}

export interface MachinePresence {
  user: string;
  since: number;
}

/** One machine as GET /v1/machines lists it (the fields the board reads; the rest pass through). */
export interface TeamMachine {
  id: string;
  creator?: string;
  state: MachineState;
  createdAt?: number;
  kind?: "user" | "fleet";
  visibility?: "private" | "team";
  provider?: string;
  region?: string;
  shape?: { vcpu: WireNumber; memGiB: WireNumber; diskGiB: WireNumber; gpu?: string };
  present?: MachinePresence[];
  cost?: MachineCost;
  error?: { code: string; message: string };
  workspace?: string | null;
  /** A name, when the machine has one (the Cloud app's machines do; the team list does not yet). */
  name?: string | null;
  /** Who or what started it, when the platform records it (a workflow run, a lane, an agent). */
  origin?: MachineOrigin | null;
}

export interface MachineOrigin {
  kind: "person" | "agent" | "workflow" | "lane";
  /** What a person reads: `Buyers probe #42813382491`, `lane one-board`, `Claude`. */
  label: string;
  url?: string;
}

export interface MachineHours {
  user?: string;
  machineId?: string;
  hours: WireNumber;
  costUsd: number;
}

export interface MachineUsage {
  since: number;
  until: number;
  knownCostUsd: number;
  totalCostUsd: number | null;
  byCreator: MachineHours[];
  byStartedBy: MachineHours[];
  byMachine: MachineHours[];
  coverage?: { scope: "team" | "visible"; recordedHistory: "all" | "truncated" };
}

export interface MachineAuditRow {
  at: number;
  target: "machine" | "snapshot";
  targetId: string;
  creator: string;
  actor: string;
  actorKind: "person" | "agent";
  action: string;
  result: string;
  made?: string;
}

export interface TeamMember {
  user: string;
  name?: string;
  email?: string;
}

/** What one agent session on a machine is doing, when the host knows (the machine's daemon). */
export interface MachineSession {
  id: string;
  agent: string;
  title?: string;
  state: "working" | "waiting" | "idle";
  /** Since when it has waited on a person (ms). */
  waitingSince?: number;
}

export interface BoardSnapshot {
  machines: TeamMachine[];
  usage?: MachineUsage | null;
  audit?: MachineAuditRow[] | null;
  members?: TeamMember[] | null;
  /** Agent sessions by machine id, when the host knows them. */
  sessions?: Record<string, MachineSession[]> | null;
  /** The signed-in person (their own machines say "You"). */
  self?: string | null;
}

export type BoardEvent =
  | { kind: "snapshot"; snapshot: BoardSnapshot }
  | { kind: "machine"; machine: TeamMachine }
  | { kind: "gone"; id: string }
  | { kind: "audit"; row: MachineAuditRow }
  | { kind: "sessions"; machine: string; sessions: MachineSession[] };
