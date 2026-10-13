import { HexclaveApiError } from "./serverApi";
import { applyHexclaveTarget, type HexclaveSyncDependencies, type HexclaveSyncTarget } from "./sync";

/**
 * The durable Hexclave webhook inbox.
 *
 * Svix redelivers a failed delivery on its own schedule, and every delivery
 * used to make up to four Hexclave reads inside the request. After a Hexclave
 * throttle, the redelivery burst (300+ events) was itself enough to keep
 * Hexclave throttling us, and events crept toward Svix's attempt limit.
 *
 * Now a verified delivery is stored here and answered 200 at once. A drain
 * applies stored events with a global concurrency of `DRAIN_SLOTS`, one
 * entity at a time per drain, coalescing every pending event of one user or
 * team into a single fresh Hexclave read. A Hexclave 429, 5xx or timeout
 * stops the drain and reschedules what it claimed after Hexclave's
 * Retry-After (or a bounded backoff). Rows are deleted only after their
 * reconcile succeeded and was recorded, so nothing is lost; a crash leaves
 * claims that expire and are drained again (every step is idempotent).
 */
export type HexclaveInboxEntry = {
  readonly svixId: string;
  readonly eventType: string;
  readonly target: HexclaveSyncTarget;
  readonly attempts: number;
};

export type HexclaveInboxStore = {
  /** Store a verified delivery. A svix id already stored is left as is. */
  enqueue(input: {
    readonly svixId: string;
    readonly eventType: string;
    readonly target: HexclaveSyncTarget;
    readonly payload: unknown;
  }): Promise<void>;
  /** Lease one of `slots` drain slots, or null when all are held. */
  claimDrainSlot(now: Date, leaseUntil: Date, slots: number): Promise<number | null>;
  releaseDrainSlot(slot: number): Promise<void>;
  /**
   * Claim every due, unclaimed entry of up to `entityLimit` entities, oldest
   * entity first. Concurrent drains claim disjoint entries.
   */
  claimDue(now: Date, entityLimit: number, leaseUntil: Date): Promise<readonly HexclaveInboxEntry[]>;
  /** Applied: delete the entries. */
  complete(svixIds: readonly string[]): Promise<void>;
  /** Not applied: count the attempt, release the claim, and schedule the next. */
  retryLater(svixIds: readonly string[], input: { readonly nextAttemptAt: Date; readonly error: string }): Promise<void>;
  /** Entries that have failed at least `attempts` times (for alerting). */
  countStuck(attempts: number): Promise<number>;
};

export const DRAIN_SLOTS = 2;
const DRAIN_LEASE_MS = 2 * 60_000;
const RETRY_BASE_MS = 30_000;
const RETRY_MAX_MS = 60 * 60_000;
/** Without a Retry-After, wait this long after a Hexclave throttle. */
const THROTTLE_DEFAULT_MS = 60_000;
export const STUCK_ATTEMPTS = 10;

export type DrainResult = {
  readonly skipped: boolean;
  readonly entities: number;
  readonly events: number;
  readonly deferredEvents: number;
  readonly throttled: boolean;
};

/**
 * Drain the inbox once. The webhook kicks it after each delivery (bounded by
 * `entityLimit`), and the cron runs it every minute.
 */
export async function drainHexclaveInbox(input: {
  readonly inbox: HexclaveInboxStore;
  readonly sync: HexclaveSyncDependencies;
  readonly entityLimit: number;
  readonly now?: () => Date;
  readonly log?: (level: "info" | "warn" | "error", message: string, fields: Record<string, unknown>) => void;
}): Promise<DrainResult> {
  const now = input.now ?? (() => new Date());
  const log = input.log ?? (() => {});
  const start = now();
  const slot = await input.inbox.claimDrainSlot(start, new Date(start.getTime() + DRAIN_LEASE_MS), DRAIN_SLOTS);
  if (slot === null) return { skipped: true, entities: 0, events: 0, deferredEvents: 0, throttled: false };
  try {
    const entries = await input.inbox.claimDue(start, input.entityLimit, new Date(start.getTime() + DRAIN_LEASE_MS));
    const groups = groupByEntity(entries);
    let applied = 0;
    let appliedEvents = 0;
    for (let index = 0; index < groups.length; index++) {
      const group = groups[index]!;
      const ids = group.entries.map((entry) => entry.svixId);
      try {
        await applyHexclaveTarget(group.target, input.sync);
      } catch (error) {
        const transient = isTransientHexclaveFailure(error);
        const attempts = Math.max(...group.entries.map((entry) => entry.attempts)) + 1;
        const delayMs = transient
          ? Math.max(retryAfterMs(error) ?? THROTTLE_DEFAULT_MS, backoffMs(attempts))
          : backoffMs(attempts);
        const summary = errorSummary(error);
        if (!transient) {
          log("error", "stack_webhook_inbox_apply_failed", { entity: group.target.kind, attempts, error: summary });
          await input.inbox.retryLater(ids, { nextAttemptAt: new Date(now().getTime() + delayMs), error: summary });
          continue;
        }
        // Hexclave is throttling or failing: stop, and give everything this
        // drain still holds the same delay instead of hammering it.
        const remaining = groups.slice(index).flatMap((rest) => rest.entries.map((entry) => entry.svixId));
        log("warn", "stack_webhook_inbox_provider_unavailable", { attempts, delayMs, deferred: remaining.length, error: summary });
        await input.inbox.retryLater(remaining, { nextAttemptAt: new Date(now().getTime() + delayMs), error: summary });
        return { skipped: false, entities: applied, events: appliedEvents, deferredEvents: remaining.length, throttled: true };
      }
      for (const entry of group.entries) {
        await input.sync.store.recordEvent({ svixId: entry.svixId, eventType: entry.eventType, outcome: "processed" });
      }
      await input.inbox.complete(ids);
      applied += 1;
      appliedEvents += ids.length;
    }
    return { skipped: false, entities: applied, events: appliedEvents, deferredEvents: 0, throttled: false };
  } finally {
    await input.inbox.releaseDrainSlot(slot);
  }
}

type EntityGroup = { readonly target: HexclaveSyncTarget; readonly entries: HexclaveInboxEntry[] };

/** One target per user or team, with the union of the events' revoke candidates. */
function groupByEntity(entries: readonly HexclaveInboxEntry[]): EntityGroup[] {
  const groups = new Map<string, { kind: HexclaveSyncTarget["kind"]; id: string; candidates: Set<string>; entries: HexclaveInboxEntry[] }>();
  for (const entry of entries) {
    const key = `${entry.target.kind}:${entry.target.id}`;
    const group = groups.get(key) ?? { kind: entry.target.kind, id: entry.target.id, candidates: new Set<string>(), entries: [] };
    for (const teamId of entry.target.revokeCandidateTeamIds) group.candidates.add(teamId);
    group.entries.push(entry);
    groups.set(key, group);
  }
  return [...groups.values()].map((group) => ({
    target: { kind: group.kind, id: group.id, revokeCandidateTeamIds: [...group.candidates].sort() },
    entries: group.entries,
  }));
}

function backoffMs(attempts: number): number {
  return Math.min(RETRY_BASE_MS * 2 ** Math.max(0, attempts - 1), RETRY_MAX_MS);
}

function retryAfterMs(error: unknown): number | null {
  if (!(error instanceof HexclaveApiError)) return null;
  const seconds = error.details.retryAfterSeconds;
  return seconds === undefined ? null : Math.min(seconds * 1_000, RETRY_MAX_MS);
}

/**
 * A Hexclave answer of 429 or 5xx, or a read that timed out or never
 * connected. Schema failures and our own database or revocation failures are
 * not transient provider failures.
 */
export function isTransientHexclaveFailure(error: unknown): boolean {
  if (error instanceof HexclaveApiError) {
    const status = error.details.status;
    return status === 429 || (status !== undefined && status >= 500);
  }
  if (!(error instanceof Error)) return false;
  // AbortSignal.timeout rejects with a TimeoutError DOMException; undici
  // rejects a failed connection with `TypeError: fetch failed`.
  return error.name === "TimeoutError" ||
    (error.name === "TypeError" && error.message === "fetch failed");
}

/** Name, Postgres code and the first line of the message, without bound parameters. */
function errorSummary(error: unknown): string {
  if (!(error instanceof Error)) return typeof error;
  const status = error instanceof HexclaveApiError ? error.details.status : undefined;
  const message = (error.message.split("\n")[0] ?? "").split(/params:/i)[0]!.slice(0, 200);
  return `${error.name}${status ? ` ${status}` : ""}: ${message}`;
}
