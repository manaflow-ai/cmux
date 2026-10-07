/**
 * One tenant's counters: rate-limit buckets, in-flight create reservations and
 * idempotency records. Pure logic over a small key-value storage, so the
 * Durable Object (one per tenant, which serializes every call) and the tests
 * run the same code.
 *
 * Nothing here holds a secret, a command or a provider id: idempotency records
 * keep only a request fingerprint and public cmux ids.
 */
import { Schema } from "effect";

/** The subset of Durable Object storage the ledger uses. Values come back untyped and are checked on read. */
export interface LedgerStorage {
  get(key: string): Promise<unknown>;
  put(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<boolean>;
  list(options: { readonly prefix: string; readonly limit?: number }): Promise<Map<string, unknown>>;
}

export type RateClass = "read" | "write" | "exec" | "files";

export interface RateRule {
  /** Requests allowed per minute (also the burst size). */
  readonly perMinute: number;
}

export const RateDecision = Schema.Union(
  Schema.Struct({ ok: Schema.Literal(true) }),
  Schema.Struct({ ok: Schema.Literal(false), retryAfterSeconds: Schema.Number }),
);
export type RateDecision = typeof RateDecision.Type;

/**
 * Progress a create or fork made under one idempotency key: pending (claimed,
 * nothing made yet), snapshotted (a fork took its snapshot, public id, but
 * has not created the VM), done (the VM, public id).
 */
const Progress = Schema.Union(
  Schema.Struct({ phase: Schema.Literal("pending") }),
  Schema.Struct({ phase: Schema.Literal("snapshotted"), snapshotId: Schema.String }),
  Schema.Struct({ phase: Schema.Literal("done"), vmId: Schema.String }),
);
export type IdempotencyProgress = typeof Progress.Type;

/**
 * new: the key is claimed for this request. resume: same key and request,
 * earlier progress to resume or replay. in_progress: another request holds the
 * key right now. mismatch: the key was used with a different request.
 */
export const IdempotencyBegin = Schema.Union(
  Schema.Struct({ state: Schema.Literal("new") }),
  Schema.Struct({ state: Schema.Literal("resume"), progress: Progress }),
  Schema.Struct({ state: Schema.Literal("in_progress") }),
  Schema.Struct({ state: Schema.Literal("mismatch") }),
);
export type IdempotencyBegin = typeof IdempotencyBegin.Type;

export const ReserveDecision = Schema.Union(
  Schema.Struct({ ok: Schema.Literal(true), reservationId: Schema.String }),
  Schema.Struct({ ok: Schema.Literal(false) }),
);
export type ReserveDecision = typeof ReserveDecision.Type;

const Bucket = Schema.Struct({ tokens: Schema.Number, updatedMs: Schema.Number });

const IdempotencyRecord = Schema.Struct({
  fingerprint: Schema.String,
  progress: Progress,
  /** While pending: when the claim lapses if its request died. */
  leaseUntilMs: Schema.Number,
  expiresMs: Schema.Number,
});

const Reservation = Schema.Struct({ kind: Schema.String, expiresMs: Schema.Number });

const isBucket = Schema.is(Bucket);
const isRecord = Schema.is(IdempotencyRecord);
const isReservation = Schema.is(Reservation);

/** A stored value of the wrong shape (from an older version) reads as absent. */
const checked = <T>(guard: (value: unknown) => value is T, value: unknown): T | undefined => (guard(value) ? value : undefined);

/** Idempotency records live for a day, as clients retry within minutes to hours. */
export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;
/** A pending claim whose request died is released after this long. */
export const IDEMPOTENCY_LEASE_MS = 2 * 60 * 1000;
/** A reservation whose create died is released after this long. */
export const RESERVATION_TTL_MS = 5 * 60 * 1000;

export class TenantLedger {
  constructor(private readonly storage: LedgerStorage) {}

  /** Token bucket per class: `perMinute` tokens, refilled continuously. */
  async rate(rateClass: RateClass, rule: RateRule, nowMs: number): Promise<RateDecision> {
    const key = `rate:${rateClass}`;
    const capacity = Math.max(1, rule.perMinute);
    const refillPerMs = capacity / 60_000;
    const stored = checked(isBucket, await this.storage.get(key));
    const elapsed = stored === undefined ? 0 : Math.max(0, nowMs - stored.updatedMs);
    const tokens = Math.min(capacity, (stored?.tokens ?? capacity) + elapsed * refillPerMs);
    if (tokens < 1) {
      await this.storage.put(key, { tokens, updatedMs: nowMs });
      return { ok: false, retryAfterSeconds: Math.max(1, Math.ceil((1 - tokens) / refillPerMs / 1000)) };
    }
    await this.storage.put(key, { tokens: tokens - 1, updatedMs: nowMs });
    return { ok: true };
  }

  /**
   * Reserves room for one more resource of `kind` when the tenant's live
   * count (from the ownership table) plus creates in flight stays under
   * `limit`. Release the reservation once the resource is recorded or failed.
   */
  async reserve(kind: string, limit: number, liveCount: number, nowMs: number, reservationId: string): Promise<ReserveDecision> {
    const live = await this.storage.list({ prefix: "reserve:" });
    let inFlight = 0;
    for (const [key, value] of live) {
      const reservation = checked(isReservation, value);
      if (reservation === undefined || reservation.expiresMs <= nowMs) await this.storage.delete(key);
      else if (reservation.kind === kind) inFlight += 1;
    }
    if (liveCount + inFlight >= limit) return { ok: false };
    await this.storage.put(`reserve:${reservationId}`, { kind, expiresMs: nowMs + RESERVATION_TTL_MS });
    return { ok: true, reservationId };
  }

  async release(reservationId: string): Promise<void> {
    await this.storage.delete(`reserve:${reservationId}`);
  }

  /** Claims `key` for a request with `fingerprint`, or reports what an earlier request with the key did. */
  async begin(key: string, fingerprint: string, nowMs: number): Promise<IdempotencyBegin> {
    const storageKey = `idem:${key}`;
    const record = checked(isRecord, await this.storage.get(storageKey));
    if (record !== undefined && record.expiresMs > nowMs) {
      if (record.fingerprint !== fingerprint) return { state: "mismatch" };
      if (record.progress.phase === "done") return { state: "resume", progress: record.progress };
      if (record.leaseUntilMs > nowMs) return { state: "in_progress" };
      if (record.progress.phase === "snapshotted") {
        await this.storage.put(storageKey, { ...record, leaseUntilMs: nowMs + IDEMPOTENCY_LEASE_MS });
        return { state: "resume", progress: record.progress };
      }
    }
    await this.storage.put(storageKey, {
      fingerprint,
      progress: { phase: "pending" },
      leaseUntilMs: nowMs + IDEMPOTENCY_LEASE_MS,
      expiresMs: nowMs + IDEMPOTENCY_TTL_MS,
    });
    await this.sweep(nowMs);
    return { state: "new" };
  }

  /** Records progress under a claimed key. A `done` record also ends the claim. */
  async advance(key: string, progress: IdempotencyProgress, nowMs: number): Promise<void> {
    const storageKey = `idem:${key}`;
    const record = checked(isRecord, await this.storage.get(storageKey));
    if (record === undefined) return;
    await this.storage.put(storageKey, {
      ...record,
      progress,
      leaseUntilMs: progress.phase === "done" ? nowMs : nowMs + IDEMPOTENCY_LEASE_MS,
    });
  }

  /**
   * Ends a claim whose request failed. A key with no progress is forgotten so
   * the client can retry it; a fork that kept a snapshot stays resumable.
   */
  async abandon(key: string, nowMs: number): Promise<void> {
    const storageKey = `idem:${key}`;
    const record = checked(isRecord, await this.storage.get(storageKey));
    if (record === undefined) return;
    if (record.progress.phase === "pending") await this.storage.delete(storageKey);
    else await this.storage.put(storageKey, { ...record, leaseUntilMs: nowMs });
  }

  /** Drops a bounded number of expired idempotency records. */
  private async sweep(nowMs: number): Promise<void> {
    const records = await this.storage.list({ prefix: "idem:", limit: 64 });
    for (const [key, value] of records) {
      const record = checked(isRecord, value);
      if (record === undefined || record.expiresMs <= nowMs) await this.storage.delete(key);
    }
  }
}

/** A LedgerStorage in memory, for tests and local tools. */
export function memoryLedgerStorage(): LedgerStorage {
  const values = new Map<string, unknown>();
  return {
    get: async (key) => structuredClone(values.get(key)),
    put: async (key, value) => {
      values.set(key, structuredClone(value));
    },
    delete: async (key) => values.delete(key),
    list: async (options) => {
      const out = new Map<string, unknown>();
      for (const key of [...values.keys()].sort()) {
        if (!key.startsWith(options.prefix)) continue;
        out.set(key, structuredClone(values.get(key)));
        if (options.limit !== undefined && out.size >= options.limit) break;
      }
      return out;
    },
  };
}
