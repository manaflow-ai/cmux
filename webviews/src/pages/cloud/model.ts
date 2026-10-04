// Pure presentation logic of the Cloud page: the machine mirror, the pending intent log and the
// rows the list draws (OWNERSHIP-PRINCIPLES "Clients are projections": visible = mirror + pending
// intents; an intent leaves the log on its echo or its reject). No I/O, no timers.
import { format, L, type StringKey } from "./strings";
import type { CloudMachine, CloudPlan, MachineEvent, MachineSize, MachineStatus, PlanSize } from "./ops";

/** The machine list layout (Debug setting `cloud.machines.layout`, README.md). */
export type MachineLayout = "rows" | "cards";

export function parseLayout(value: string | null | undefined): MachineLayout {
  return value === "cards" ? "cards" : "rows";
}

export type IntentKind = "create" | "start" | "pause" | "rename" | "resize" | "delete" | "idle";

/** One typed intent the page sent and the owner has not echoed or rejected yet. */
export interface PendingIntent {
  key: string;
  kind: IntentKind;
  machine?: string;
  name?: string;
  size?: string;
  idle?: number | null;
  /** The machine id the owner answered for a create. */
  result_id?: string;
  /** The owner answered; its next event for the machine is the echo. */
  replied?: boolean;
}

export interface MachineRow {
  id: string;
  title: string;
  status: MachineStatus;
  machine?: CloudMachine;
  pending?: IntentKind;
}

export function machineTitle(machine: CloudMachine): string {
  return machine.display_name || machine.slug || machine.id;
}

const STATUSES = new Set<string>(["provisioning", "running", "failed", "paused", "destroyed", "unknown"]);

/** A status the page does not know becomes `unknown`, like the Swift decoder. */
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

/** True when the mirror already shows the intent's effect (its echo). */
export function settled(intent: PendingIntent, machines: CloudMachine[]): boolean {
  if (intent.kind === "create") return !!intent.result_id && machines.some((m) => m.id === intent.result_id);
  const machine = machines.find((m) => m.id === intent.machine);
  if (intent.kind === "delete") return !machine;
  if (!machine) return true;
  switch (intent.kind) {
    case "pause":
      return machine.status === "paused";
    case "start":
      return machine.status === "running" || machine.status === "provisioning";
    case "rename":
      return machine.display_name === intent.name;
    case "resize":
      return machine.size?.name === intent.size;
    case "idle":
      return (machine.idle_timeout_seconds ?? null) === (intent.idle ?? null);
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
  running: L.statusRunning,
  failed: L.statusFailed,
  paused: L.statusPaused,
  destroyed: L.statusDestroyed,
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
};

export function canPause(row: MachineRow): boolean {
  return !!row.machine && !row.pending && (row.status === "running" || row.status === "provisioning");
}

export function canResume(row: MachineRow): boolean {
  return !!row.machine && !row.pending && (row.status === "paused" || row.status === "failed");
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

export function sizeSpec(size: MachineSize | PlanSize, t: (key: string) => string, language: string): string {
  return format(t(L.sizeSpec), {
    cpu: size.cpu ?? 0,
    memory: formatMegabytes(size.memory_mb ?? 0, t, language),
    storage: formatMegabytes(size.storage_mb ?? 0, t, language),
  });
}

/** Idle policy choices in seconds; null = never pause. */
export const IDLE_CHOICES: readonly (number | null)[] = [null, 300, 900, 3600, 4 * 3600];

export function idleLabel(seconds: number | null | undefined, t: (key: string) => string): string {
  if (!seconds) return t(L.idleNever);
  if (seconds % 3600 === 0) return format(t(L.idleHours), { count: seconds / 3600 });
  return format(t(L.idleMinutes), { count: Math.round(seconds / 60) });
}

export function defaultSize(plan: CloudPlan | undefined): string | undefined {
  return plan?.sizes.find((size) => size.allowed)?.name;
}

export function atMachineLimit(plan: CloudPlan | undefined, machines: CloudMachine[]): boolean {
  if (!plan) return false;
  return machines.filter((machine) => machine.status !== "destroyed").length >= plan.machine_limit;
}

export function formatDate(ms: number | undefined, language: string, withTime = true): string {
  if (!ms) return "";
  const options: Intl.DateTimeFormatOptions = withTime
    ? { dateStyle: "medium", timeStyle: "short" }
    : { dateStyle: "medium" };
  return new Intl.DateTimeFormat(language, options).format(new Date(ms));
}

export function percent(used: number | undefined, total: number | undefined): number | undefined {
  if (used === undefined || !total) return undefined;
  return Math.max(0, Math.min(100, Math.round((used / total) * 100)));
}

/** A plain key: no Cmd, Ctrl or Option. Chords belong to the app's key dispatcher, never the page. */
export function plain(event: { metaKey: boolean; ctrlKey: boolean; altKey: boolean }): boolean {
  return !event.metaKey && !event.ctrlKey && !event.altKey;
}
