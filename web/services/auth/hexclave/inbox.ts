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
 * team into a single fresh Hexclave read.
 *
 * - A Hexclave 429, 5xx or timeout sets a global backoff (Hexclave's
 *   Retry-After, or a default). No drain starts until it ends. The entity
 *   that failed counts an attempt and backs off exponentially; entries the
 *   drain had not tried yet are only deferred to the end of the global
 *   backoff, without an attempt.
 * - Any other failure counts an attempt for that entity only.
 * - After `MAX_ATTEMPTS` an entry is dead-lettered: kept for diagnosis,
 *   reported, purged after 30 days.
 * - Entries are deleted only after their reconcile succeeded and was
 *   recorded; a crash leaves claims that expire and are drained again.
 */
export type HexclaveInboxEntry = {
  readonly svixId: string;
  readonly eventType: string;
  readonly target: HexclaveSyncTarget;
  readonly attempts: number;
};

export type DrainSlotLease = { readonly slot: number; readonly leaseId: string };

export type HexclaveInboxStore = {
  /** Store a verified delivery's target. A svix id already stored is left as is. */
  enqueue(input: { readonly svixId: string; readonly eventType: string; readonly target: HexclaveSyncTarget }): Promise<void>;
  /**
   * Lease one of `slots` drain slots, or null when all are held or the global
   * Hexclave backoff has not ended.
   */
  claimDrainSlot(now: Date, leaseUntil: Date, slots: number): Promise<DrainSlotLease | null>;
  /** Release a slot, only if this lease still holds it. */
  releaseDrainSlot(lease: DrainSlotLease): Promise<void>;
  /** Hold every drain until this time (extends, never shortens). */
  throttleUntil(until: Date): Promise<void>;
  /**
   * Claim every due, unclaimed, live entry of up to `entityLimit` entities,
   * oldest entity first. Concurrent drains claim disjoint entries.
   */
  claimDue(now: Date, entityLimit: number, leaseUntil: Date): Promise<readonly HexclaveInboxEntry[]>;
  /** Applied: delete the entries. */
  complete(svixIds: readonly string[]): Promise<void>;
  /** The entity failed: count an attempt, release, schedule; dead-letter at the cap. */
  recordFailure(svixIds: readonly string[], input: {
    readonly now: Date;
    readonly nextAttemptAt: Date;
    readonly error: string;
    readonly maxAttempts: number;
  }): Promise<void>;
  /** Not tried: release the claim and schedule, without counting an attempt. */
  defer(svixIds: readonly string[], nextAttemptAt: Date): Promise<void>;
  /** The user or team is gone: drop every entry still naming it. */
  purgeEntity(target: Pick<HexclaveSyncTarget, "kind" | "id">): Promise<void>;
  /** Live entries with at least `attempts` failures, and dead-lettered entries. */
  health(attempts: number): Promise<{ readonly stuck: number; readonly deadLettered: number }>;
  /** Store the counts last alerted on; answers whether they changed. */
  recordReportedHealth(health: { readonly stuck: number; readonly deadLettered: number }): Promise<boolean>;
  /** Delete dead-lettered entries older than this. */
  purgeDeadLettered(olderThan: Date): Promise<number>;
  /** Delete the idempotency records of events applied before this. */
  purgeProcessedEvents(olderThan: Date): Promise<number>;
};

export const DRAIN_SLOTS = 2;
const DRAIN_LEASE_MS = 2 * 60_000;
const RETRY_BASE_MS = 30_000;
const RETRY_MAX_MS = 60 * 60_000;
/** Without a Retry-After, hold every drain this long after a Hexclave throttle. */
const THROTTLE_DEFAULT_MS = 60_000;
export const STUCK_ATTEMPTS = 5;
export const MAX_ATTEMPTS = 12;
export const DEAD_LETTER_RETENTION_MS = 30 * 24 * 60 * 60_000;
export const PROCESSED_EVENT_RETENTION_MS = 7 * 24 * 60 * 60_000;

export type DrainResult = {
  readonly skipped: boolean;
  readonly entities: number;
  readonly events: number;
  readonly deferredEvents: number;
  readonly throttled: boolean;
};

type DrainLog = (level: "info" | "warn" | "error", message: string, fields: Record<string, unknown>) => void;

/**
 * Drain the inbox once. The webhook kicks it after each delivery (bounded by
 * `entityLimit`), and the cron runs it every minute.
 */
export async function drainHexclaveInbox(input: {
  readonly inbox: HexclaveInboxStore;
  readonly sync: HexclaveSyncDependencies;
  readonly entityLimit: number;
  readonly now?: () => Date;
  readonly log?: DrainLog;
}): Promise<DrainResult> {
  const now = input.now ?? (() => new Date());
  const start = now();
  const lease = await input.inbox.claimDrainSlot(start, new Date(start.getTime() + DRAIN_LEASE_MS), DRAIN_SLOTS);
  if (!lease) return { skipped: true, entities: 0, events: 0, deferredEvents: 0, throttled: false };
  try {
    const entries = await input.inbox.claimDue(start, input.entityLimit, new Date(start.getTime() + DRAIN_LEASE_MS));
    return await applyGroups(groupByEntity(entries), input, now, input.log ?? (() => {}));
  } finally {
    await input.inbox.releaseDrainSlot(lease);
  }
}

async function applyGroups(
  groups: readonly EntityGroup[],
  input: { readonly inbox: HexclaveInboxStore; readonly sync: HexclaveSyncDependencies },
  now: () => Date,
  log: DrainLog,
): Promise<DrainResult> {
  let entities = 0;
  let events = 0;
  for (let index = 0; index < groups.length; index++) {
    const group = groups[index]!;
    const ids = group.entries.map((entry) => entry.svixId);
    let gone = false;
    try {
      gone = (await applyHexclaveTarget(group.target, input.sync)).gone;
    } catch (error) {
      const throttled = await recordGroupFailure(group, error, input.inbox, now(), log);
      if (!throttled) continue;
      const untried = groups.slice(index + 1).flatMap((rest) => rest.entries.map((entry) => entry.svixId));
      await input.inbox.defer(untried, throttled);
      return { skipped: false, entities, events, deferredEvents: untried.length + ids.length, throttled: true };
    }
    for (const entry of group.entries) {
      await input.sync.store.recordEvent({ svixId: entry.svixId, eventType: entry.eventType, outcome: "processed" });
    }
    await input.inbox.complete(ids);
    // A deleted user or team needs nothing more: drop entries still naming it.
    if (gone) await input.inbox.purgeEntity(group.target);
    entities += 1;
    events += ids.length;
  }
  return { skipped: false, entities, events, deferredEvents: 0, throttled: false };
}

/**
 * Count the failed entity's attempt and schedule it. On a transient Hexclave
 * failure also set the global backoff, and answer when it ends (else null).
 */
async function recordGroupFailure(
  group: EntityGroup,
  error: unknown,
  inbox: HexclaveInboxStore,
  at: Date,
  log: DrainLog,
): Promise<Date | null> {
  const attempts = Math.max(...group.entries.map((entry) => entry.attempts)) + 1;
  const summary = errorSummary(error);
  const ids = group.entries.map((entry) => entry.svixId);
  if (!isTransientHexclaveFailure(error)) {
    log("error", "stack_webhook_inbox_apply_failed", { entity: group.target.kind, attempts, error: summary });
    await inbox.recordFailure(ids, { now: at, nextAttemptAt: new Date(at.getTime() + backoffMs(attempts)), error: summary, maxAttempts: MAX_ATTEMPTS });
    return null;
  }
  const throttledUntil = new Date(at.getTime() + (retryAfterMs(error) ?? THROTTLE_DEFAULT_MS));
  await inbox.throttleUntil(throttledUntil);
  const entityRetryAt = new Date(Math.max(throttledUntil.getTime(), at.getTime() + backoffMs(attempts)));
  await inbox.recordFailure(ids, { now: at, nextAttemptAt: entityRetryAt, error: summary, maxAttempts: MAX_ATTEMPTS });
  log("warn", "stack_webhook_inbox_provider_unavailable", { attempts, throttledUntil: throttledUntil.toISOString(), error: summary });
  return throttledUntil;
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

/** Name, status and the first line of the message, without bound parameters. */
function errorSummary(error: unknown): string {
  if (!(error instanceof Error)) return typeof error;
  const status = error instanceof HexclaveApiError ? error.details.status : undefined;
  const message = (error.message.split("\n")[0] ?? "").split(/params:/i)[0]!.slice(0, 200);
  return `${error.name}${status ? ` ${status}` : ""}: ${message}`;
}
