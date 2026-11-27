// Automatic machine cleanup on the Cloud page (cmux-platform Retention.ts; Leo, 2026-11-10: "we should
// defo have auto pause or complete cleanup somethimes..."). Pure: what a row says about its delete
// date, which one-time notice it shows, what a cap refusal offers to free, and the archive list.
// The platform decides every date; the page only reads `evict_at`, `delete_reason`, `keep` and
// `notice` off the record and never computes a policy of its own.
//
// The policy the page shows: pausing is silent. Disposable machines (a create that failed, a machine
// nobody used) go silently, with at most a calm "Deletes in N days" in the row. A worked-in machine
// on a plan that deletes them gets one heads-up and one last note, each once, inline, with Keep.
// Paid plans keep worked-in machines; there a paused one offers "Archive and delete".
import { isPageError } from "../shared/pageClient";
import { CloudErrors, type CloudMachine, type CloudSnapshot, type DeleteReason } from "./ops";

export const DAY_MS = 86_400_000;

/** When a row's machine is deleted automatically, as the row says it. */
export type DeleteDate = { kind: "today" } | { kind: "tomorrow" } | { kind: "days"; days: number };

/** The machine's automatic delete date, or undefined when nothing deletes it (or it is kept). */
export function deleteDate(machine: CloudMachine | undefined, now: number): DeleteDate | undefined {
  const at = machine?.evict_at;
  if (!machine || machine.keep || typeof at !== "number" || !Number.isFinite(at)) return undefined;
  if (machine.delete_reason === "requested") return undefined;
  // Calendar days in the viewer's time zone: a delete at 23:00 tonight is "today".
  const days = calendarDays(now, at);
  if (days <= 0) return { kind: "today" };
  if (days === 1) return { kind: "tomorrow" };
  return { kind: "days", days };
}

/** Whole local calendar days from `from` to `to` (0: the same day). */
export function calendarDays(from: number, to: number): number {
  const day = (ms: number) => {
    const date = new Date(ms);
    return Date.UTC(date.getFullYear(), date.getMonth(), date.getDate());
  };
  return Math.round((day(to) - day(from)) / DAY_MS);
}

/** The machine is being archived before its delete (a person's archive and delete). */
export function archiving(machine: CloudMachine | undefined): boolean {
  return machine?.delete_reason === "requested" && typeof machine.evict_at === "number";
}

/**
 * Keep makes sense where a person may want the machine: one someone worked in (or might have), never
 * a create that never ran. A kept machine always shows its toggle, so it can be let go again.
 */
export function canKeep(machine: CloudMachine | undefined): boolean {
  if (!machine || machine.classic) return false;
  if (machine.keep) return true;
  const reason: DeleteReason | null | undefined = machine.delete_reason;
  return typeof machine.evict_at === "number" && (reason === "unused" || reason === "never_used");
}

/** Archive and delete: a paused (or failed) machine nobody pinned, not already on its way out. */
export function canArchive(machine: CloudMachine | undefined): boolean {
  if (!machine || machine.classic || machine.keep || archiving(machine)) return false;
  return machine.status === "paused" || (machine.status === "failed" && machine.host !== null);
}

/** A dismissal is remembered per machine and notice (`notice.at`): a new notice shows again. */
export function noticeKey(machine: string, at: number): string {
  return `${machine}:${at}`;
}

/** The notice a row shows once, or undefined: none, kept, or dismissed here. */
export function shownNotice(
  machine: CloudMachine | undefined,
  dismissed: ReadonlySet<string>,
): NonNullable<CloudMachine["notice"]> | undefined {
  const notice = machine?.notice;
  if (!machine || !notice || machine.keep || archiving(machine)) return undefined;
  return dismissed.has(noticeKey(machine.id, notice.at)) ? undefined : notice;
}

const DISMISSED_KEY = "cmux.cloud.retention.dismissed";
/** At most this many dismissals are remembered (oldest dropped): each names one notice of one machine. */
const DISMISSED_MAX = 200;

/** The notices dismissed in this browser profile. Storage can be absent or refuse: then none. */
export function readDismissed(storage: Pick<Storage, "getItem"> | undefined = safeStorage()): Set<string> {
  try {
    const raw = storage?.getItem(DISMISSED_KEY);
    const list: unknown = raw ? JSON.parse(raw) : [];
    return new Set(Array.isArray(list) ? list.filter((item): item is string => typeof item === "string") : []);
  } catch {
    return new Set();
  }
}

export function writeDismissed(
  dismissed: ReadonlySet<string>,
  storage: Pick<Storage, "setItem"> | undefined = safeStorage(),
): void {
  try {
    storage?.setItem(DISMISSED_KEY, JSON.stringify([...dismissed].slice(-DISMISSED_MAX)));
  } catch {
    // A private window or a full store: the notice shows again next time, nothing else changes.
  }
}

function safeStorage(): Storage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

/** What a create refused at the machines cap offers instead of only failing. */
export type CapOffer =
  /** Delete this machine (a test leftover, a failed create, a never-used one, or one already archived). */
  | { kind: "delete"; machine: string; name: string }
  /** Archive and delete the oldest paused machine (its disk kept as an archive). */
  | { kind: "archive"; machine: string; name: string }
  /** Pause this running machine of the person (the running-machines limit; its files and processes are kept). */
  | { kind: "pause"; machine: string; name: string };

/** The provider's own machine limit (paused ones count), as cmux-platform words it. Its text is
 * read only to know the cap refused; the machine to delete is only ever the id in `free_up`. */
const HELD_CAP = "machines (paused ones count)";

/**
 * The offer of a create refusal at a machines cap: the plan's (`cloud.quota.exceeded` with
 * `details.resource: "machines"` and `details.free_up`) or the provider's ("limit of 20 machines
 * (paused ones count)"). A delete is offered only for the machine id the platform names in
 * `free_up`; without one, the oldest paused machine nobody kept is archived and deleted. At the
 * running-machines limit (the same code without `resource: "machines"`) the offer is a pause
 * (`pauseOffer`). Undefined for any other error, or nothing to free.
 */
export function capOffer(error: unknown, machines: readonly CloudMachine[]): CapOffer | undefined {
  if (!isPageError(error)) return undefined;
  const details = (error.details && typeof error.details === "object" ? error.details : {}) as Record<string, unknown>;
  const planCap = error.code === CloudErrors.quotaExceeded && details.resource === "machines";
  const heldCap = (error.message ?? "").includes(HELD_CAP);
  if (error.code === CloudErrors.quotaExceeded && !planCap && !heldCap) return pauseOffer(details.busy, machines);
  if (!planCap && !heldCap) return undefined;
  const free = details.free_up as { machine?: unknown; name?: unknown } | null | undefined;
  if (free && typeof free.machine === "string") {
    const known = machines.find((machine) => machine.id === free.machine);
    const name = typeof free.name === "string" && free.name ? free.name : (known?.name ?? free.machine);
    return { kind: "delete", machine: free.machine, name };
  }
  const oldest = oldestPaused(machines);
  return oldest ? { kind: "archive", machine: oldest.id, name: oldest.name || oldest.id } : undefined;
}

/**
 * The offer at the running-machines limit: the platform found no idle machine of the person to pause
 * and names their running ones in `details.busy`; the one used longest ago is offered. Undefined when
 * it names none (a teammate's machines hold the slots).
 */
function pauseOffer(busy: unknown, machines: readonly CloudMachine[]): CapOffer | undefined {
  if (!Array.isArray(busy)) return undefined;
  const named = busy
    .filter((b): b is { machine: string; name?: unknown; last_active_at?: unknown } => typeof b?.machine === "string")
    .map((b) => ({ ...b, used: typeof b.last_active_at === "number" ? b.last_active_at : 0 }))
    .sort((a, b) => a.used - b.used)[0];
  if (!named) return undefined;
  const known = machines.find((machine) => machine.id === named.machine);
  const name = typeof named.name === "string" && named.name ? named.name : known?.name || named.machine;
  return { kind: "pause", machine: named.machine, name };
}

/** The paused machine used longest ago that nobody kept: the one "Archive and delete" frees first. */
export function oldestPaused(machines: readonly CloudMachine[]): CloudMachine | undefined {
  const used = (machine: CloudMachine) => machine.last_active_at ?? machine.created_at;
  return machines
    .filter((machine) => canArchive(machine) && machine.status === "paused")
    .sort((a, b) => used(a) - used(b) || a.created_at - b.created_at)[0];
}

/** The archive snapshots (`archive_of`), newest first. */
export function archives(snapshots: readonly CloudSnapshot[]): CloudSnapshot[] {
  return snapshots
    .filter((snapshot) => !!snapshot.archive_of && snapshot.status !== "deleting")
    .sort((a, b) => b.created_at - a.created_at);
}

/** The cleanup numbers a team admin may set, in the order the settings show them. */
export const RETENTION_FIELDS = [
  "never_used_hours",
  "failed_create_hours",
  "worked_in_days",
  "heads_up_days",
  "archive_days",
] as const;

export type RetentionField = (typeof RETENTION_FIELDS)[number];

/** The plan's own limit of one number: a team may clean up sooner, never keep longer. */
export function retentionLimit(field: RetentionField): { min: number; max: number } {
  switch (field) {
    case "never_used_hours":
    case "failed_create_hours":
      return { min: 1, max: 168 };
    case "worked_in_days":
      return { min: 2, max: 3650 };
    case "heads_up_days":
      return { min: 1, max: 365 };
    case "archive_days":
      return { min: 1, max: 3650 };
  }
}
