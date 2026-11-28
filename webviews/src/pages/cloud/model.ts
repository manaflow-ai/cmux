// Pure presentation logic of the Cloud page: the machine mirror, the pending intent log and the
// rows the list draws (OWNERSHIP-PRINCIPLES "Clients are projections": visible = mirror + pending
// intents; an intent leaves the log on its echo or its reject). No I/O, no timers.
import { format, L, type StringKey } from "./strings";
import type { CloudMachine, CloudPlan, MachineEvent, MachineSize, MachineStatus } from "./ops";

/** The machine list layout (Debug setting `cloud.machines.layout`, README.md). */
export type MachineLayout = "rows" | "cards";

export function parseLayout(value: string | null | undefined): MachineLayout {
  return value === "cards" ? "cards" : "rows";
}

export type IntentKind = "create" | "start" | "pause" | "rename" | "resize" | "delete" | "idle" | "upgrade";

/** One typed intent the page sent and the owner has not echoed or rejected yet. */
export interface PendingIntent {
  key: string;
  kind: IntentKind;
  machine?: string;
  name?: string;
  memoryMb?: number;
  idle?: number | null;
  /** The machine id the owner answered for a create (or a restore). */
  result_id?: string;
  /** The owner answered; its next event for the machine is the echo. */
  replied?: boolean;
  /** The projection revision the owner's answer reached: the mirror at it settles the intent. */
  revision?: number;
}

export interface MachineRow {
  id: string;
  title: string;
  status: MachineStatus;
  machine?: CloudMachine;
  pending?: IntentKind;
  /** Imported from cmux Cloud classic: read-only until upgraded (contract 4). */
  classic?: boolean;
}

export function machineTitle(machine: CloudMachine): string {
  return machine.name || machine.id;
}

const STATUSES = new Set<string>([
  "provisioning",
  "starting",
  "running",
  "pausing",
  "paused",
  "deleting",
  "failed",
  "unknown",
]);

/** A status the page does not know becomes `unknown`, like the server's decoder. */
export function normalizeMachine(machine: CloudMachine): CloudMachine {
  return STATUSES.has(machine.status) ? machine : { ...machine, status: "unknown" };
}

/** Applies one watch event to the mirror. */
export function applyEvent(machines: CloudMachine[], event: MachineEvent): CloudMachine[] {
  if (event.type === "removed") return machines.filter((machine) => machine.id !== event.id);
  const machine = normalizeMachine(event.machine);
  const index = machines.findIndex((m) => m.id === machine.id);
  if (index < 0) return [...machines, machine];
  const next = machines.slice();
  next[index] = machine;
  return next;
}

/**
 * True when the mirror already shows the intent's effect (its echo): the mirror reached the
 * revision the owner answered, or it shows the change itself.
 */
export function settled(intent: PendingIntent, machines: CloudMachine[], revision = 0): boolean {
  if (intent.revision !== undefined && intent.revision <= revision) return true;
  if (intent.kind === "create") return !!intent.result_id && machines.some((m) => m.id === intent.result_id);
  const machine = machines.find((m) => m.id === intent.machine);
  if (intent.kind === "delete") return !machine;
  if (!machine) return true;
  switch (intent.kind) {
    case "pause":
      return machine.status === "paused" || machine.status === "pausing";
    case "start":
      return machine.status === "running" || machine.status === "starting";
    case "rename":
      return machine.name === intent.name;
    case "resize":
      return intent.memoryMb !== undefined && machine.size?.memory_mb === intent.memoryMb;
    case "idle":
      return (machine.idle_policy?.idle_seconds ?? 0) === (intent.idle ?? 0);
    case "upgrade":
      return !machine.classic;
  }
}

/** The rows the list draws: every mirrored machine with its newest pending intent, then creates. */
export function visibleRows(machines: CloudMachine[], pending: PendingIntent[]): MachineRow[] {
  const rows: MachineRow[] = machines.map((machine) => {
    const intents = pending.filter((intent) => intent.machine === machine.id);
    const rename = [...intents].reverse().find((intent) => intent.kind === "rename");
    return {
      id: machine.id,
      title: rename?.name ?? machineTitle(machine),
      status: machine.status,
      machine,
      pending: intents.at(-1)?.kind,
      ...(machine.classic ? { classic: true } : {}),
    };
  });
  for (const intent of pending) {
    if (intent.kind !== "create") continue;
    if (intent.result_id && machines.some((machine) => machine.id === intent.result_id)) continue;
    rows.push({ id: `pending:${intent.key}`, title: intent.name ?? "", status: "provisioning", pending: "create" });
  }
  return rows;
}

export const StatusLabel: Record<MachineStatus, StringKey> = {
  provisioning: L.statusProvisioning,
  starting: L.statusStarting,
  running: L.statusRunning,
  pausing: L.statusPausing,
  paused: L.statusPaused,
  deleting: L.statusDeleting,
  failed: L.statusFailed,
  unknown: L.statusUnknown,
};

export const IntentLabel: Record<IntentKind, StringKey> = {
  create: L.pendingCreate,
  start: L.pendingStart,
  pause: L.pendingPause,
  rename: L.pendingRename,
  resize: L.pendingResize,
  delete: L.pendingDelete,
  idle: L.pendingIdle,
  upgrade: L.pendingUpgrade,
};

/** A status between two steady states: the dot shows it as in progress. */
export function transitional(status: MachineStatus): boolean {
  return status === "provisioning" || status === "starting" || status === "pausing" || status === "deleting";
}

/** A row the person may change: a real machine, no pending intent, not classic. */
export function changeable(row: MachineRow): boolean {
  return !!row.machine && !row.pending && !row.classic;
}

export function canPause(row: MachineRow): boolean {
  return changeable(row) && (row.status === "running" || row.status === "starting");
}

export function canResume(row: MachineRow): boolean {
  return changeable(row) && (row.status === "paused" || row.status === "failed");
}

/** The next selectable row id for plain Up/Down. */
export function moveSelection(rows: MachineRow[], selection: string | undefined, delta: 1 | -1): string | undefined {
  const real = rows.filter((row) => row.machine);
  if (real.length === 0) return undefined;
  const index = real.findIndex((row) => row.id === selection);
  if (index < 0) return (delta > 0 ? real[0] : real.at(-1))?.id;
  return real[Math.max(0, Math.min(real.length - 1, index + delta))].id;
}

export function formatMegabytes(mb: number, t: (key: string) => string, language: string): string {
  const gb = mb / 1024;
  const value = new Intl.NumberFormat(language, { maximumFractionDigits: gb < 10 ? 1 : 0 }).format(gb);
  return format(t(L.gigabytes), { value });
}

/** "4 CPU · 8 GB memory · 64 GB disk" from the machine record's size. */
export function sizeSpec(size: MachineSize, t: (key: string) => string, language: string): string {
  return format(t(L.sizeSpec), {
    cpu: size.cpu ?? 0,
    memory: formatMegabytes(size.memory_mb ?? 0, t, language),
    storage: formatMegabytes(size.disk_mb ?? 0, t, language),
  });
}

/** Idle policy choices in seconds; null = never pause (sent as 0). */
export const IDLE_CHOICES: readonly (number | null)[] = [null, 300, 900, 3600, 4 * 3600];

export function idleLabel(seconds: number | null | undefined, t: (key: string) => string): string {
  if (!seconds) return t(L.idleNever);
  if (seconds % 3600 === 0) return format(t(L.idleHours), { count: seconds / 3600 });
  return format(t(L.idleMinutes), { count: Math.round(seconds / 60) });
}

/** One memory size of the plan and whether the plan allows it (locked sizes show disabled). */
export interface MemoryChoice {
  mb: number;
  allowed: boolean;
}

/** The plan's memory sizes, locked ones included and marked, smallest first. */
export function memoryChoices(plan: CloudPlan | undefined): MemoryChoice[] {
  if (!plan) return [];
  const locked = new Set(plan.limits.locked_memory_options_mb);
  const all = new Set([...plan.limits.memory_options_mb, ...plan.limits.locked_memory_options_mb]);
  return [...all].sort((a, b) => a - b).map((mb) => ({ mb, allowed: !locked.has(mb) }));
}

/** The first memory size the plan allows; undefined when the plan did not load or allows none. */
export function defaultMemory(plan: CloudPlan | undefined): number | undefined {
  return memoryChoices(plan).find((choice) => choice.allowed)?.mb;
}

export function formatDate(value: number | null | undefined, language: string, withTime = true): string {
  if (typeof value !== "number" || !Number.isFinite(value) || !value) return "";
  const options: Intl.DateTimeFormatOptions = withTime
    ? { dateStyle: "medium", timeStyle: "short" }
    : { dateStyle: "medium" };
  return new Intl.DateTimeFormat(language, options).format(new Date(value));
}

export function percent(used: number | null | undefined, total: number | null | undefined): number | undefined {
  if (used === undefined || used === null || !total) return undefined;
  return Math.max(0, Math.min(100, Math.round((used / total) * 100)));
}

/** A plain key: no Cmd, Ctrl or Option. Chords belong to the app's key dispatcher, never the page. */
export function plain(event: { metaKey: boolean; ctrlKey: boolean; altKey: boolean }): boolean {
  return !event.metaKey && !event.ctrlKey && !event.altKey;
}
