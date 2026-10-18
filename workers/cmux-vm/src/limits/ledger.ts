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
  transaction<A>(run: (storage: LedgerStorage) => Promise<A>): Promise<A>;
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
 * no VM send yet), creating (durable allocation/context and retained quota),
 * snapshotted (a fork took its snapshot, public id, but
 * has not created the VM), done (the VM, public id), snapshotDone (a snapshot
 * create finished, public snapshot id).
 */
const Progress = Schema.Union(
  Schema.Struct({ phase: Schema.Literal("pending") }),
  Schema.Struct({ phase: Schema.Literal("creating"), vmId: Schema.String, reservationId: Schema.String, context: Schema.String, createdBy: Schema.String, snapshotId: Schema.optional(Schema.String) }),
  Schema.Struct({ phase: Schema.Literal("snapshotted"), snapshotId: Schema.String }),
  Schema.Struct({ phase: Schema.Literal("done"), vmId: Schema.String }),
  Schema.Struct({ phase: Schema.Literal("snapshotDone"), snapshotId: Schema.String }),
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
  Schema.Struct({ state: Schema.Literal("in_progress"), progress: Schema.optional(Progress) }),
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

const Reservation = Schema.Struct({ kind: Schema.String, expiresMs: Schema.Number, retained: Schema.optional(Schema.Boolean) });

const isBucket = Schema.is(Bucket);
const isRecord = Schema.is(IdempotencyRecord);
const isReservation = Schema.is(Reservation);

const Lock = Schema.Struct({ holder: Schema.String, untilMs: Schema.Number });
const isLock = Schema.is(Lock);

/** A stored value of the wrong shape (from an older version) reads as absent. */
const checked = <T>(guard: (value: unknown) => value is T, value: unknown): T | undefined => (guard(value) ? value : undefined);

/** Idempotency records live for a day, as clients retry within minutes to hours. */
export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;
/**
 * A pending claim whose request died is released after this long. It exceeds
 * the longest create or fork (snapshot, create and grow, 120 s upstream timeout
 * each), so a live request never loses its claim to a retry.
 */
export const IDEMPOTENCY_LEASE_MS = 10 * 60 * 1000;
/** An ordinary reservation expires after this long; an uncertain allocation retains its slot. */
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
    return this.storage.transaction(async (storage) => {
      const live = await storage.list({ prefix: "reserve:" });
      let inFlight = 0;
      for (const [key, value] of live) {
        const reservation = checked(isReservation, value);
        if (reservation === undefined || (reservation.retained !== true && reservation.expiresMs <= nowMs)) await storage.delete(key);
        else if (reservation.kind === kind) inFlight += 1;
      }
      if (liveCount + inFlight >= limit) return { ok: false };
      await storage.put(`reserve:${reservationId}`, { kind, expiresMs: nowMs + RESERVATION_TTL_MS });
      return { ok: true, reservationId };
    });
  }

  async release(reservationId: string): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const held = checked(isReservation, await storage.get(`reserve:${reservationId}`));
      if (held?.retained !== true) await storage.delete(`reserve:${reservationId}`);
    });
  }

  /** A retry reuses only the quota slot durably attached to this exact allocation intent. */
  async creationReservation(key: string, vmId: string): Promise<string | null> {
    return this.storage.transaction(async (storage) => {
      const record = checked(isRecord, await storage.get(`idem:${key}`));
      if (record?.progress.phase !== "creating" || record.progress.vmId !== vmId) return null;
      const held = checked(isReservation, await storage.get(`reserve:${record.progress.reservationId}`));
      return held?.kind === "vm" && held.retained === true ? record.progress.reservationId : null;
    });
  }

  /** Claims `key` for a request with `fingerprint`, or reports what an earlier request with the key did. */
  async begin(key: string, fingerprint: string, nowMs: number): Promise<IdempotencyBegin> {
    return this.storage.transaction(async (storage) => {
      const storageKey = `idem:${key}`;
      const raw = await storage.get(storageKey), record = checked(isRecord, raw);
      if (raw !== undefined && record === undefined) throw new Error("unrecognized idempotency record");
      if (record !== undefined && (record.expiresMs > nowMs || record.progress.phase === "creating")) {
        if (record.fingerprint !== fingerprint) return { state: "mismatch" };
        if (record.progress.phase === "done" || record.progress.phase === "snapshotDone") return { state: "resume", progress: record.progress };
        if (record.leaseUntilMs > nowMs) return record.progress.phase === "creating" ? { state: "in_progress", progress: record.progress } : { state: "in_progress" };
        if (record.progress.phase === "snapshotted" || record.progress.phase === "creating") {
          await storage.put(storageKey, { ...record, leaseUntilMs: nowMs + IDEMPOTENCY_LEASE_MS });
          return { state: "resume", progress: record.progress };
        }
      }
      await storage.put(storageKey, {
        fingerprint,
        progress: { phase: "pending" },
        leaseUntilMs: nowMs + IDEMPOTENCY_LEASE_MS,
        expiresMs: nowMs + IDEMPOTENCY_TTL_MS,
    });
    await this.sweep(storage, nowMs);
    return { state: "new" };
    });
  }

  /** Records progress under a claimed key. A finished record (`done`, `snapshotDone`) also ends the claim. */
  async advance(key: string, progress: IdempotencyProgress, nowMs: number): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const storageKey = `idem:${key}`;
      const record = checked(isRecord, await storage.get(storageKey));
      if (record === undefined) throw new Error("missing idempotency claim");
      if (record.progress.phase === "done" || record.progress.phase === "snapshotDone") {
        if (JSON.stringify(record.progress) === JSON.stringify(progress)) return;
        throw new Error("a completed idempotency record cannot change");
      }
      if (record.leaseUntilMs <= nowMs) throw new Error("idempotency claim expired");
      if (record.progress.phase === "creating") {
        const prior = record.progress;
        if (progress.phase === "creating" && (progress.vmId !== prior.vmId || progress.reservationId !== prior.reservationId || progress.context !== prior.context || progress.createdBy !== prior.createdBy || progress.snapshotId !== prior.snapshotId)) throw new Error("allocation intent changed");
        if (progress.phase !== "creating" && (progress.phase !== "done" || progress.vmId !== prior.vmId)) throw new Error("allocation intent cannot be replaced");
        if (progress.phase === "done") await storage.delete(`reserve:${prior.reservationId}`);
      }
      if (progress.phase === "creating") {
        const held = checked(isReservation, await storage.get(`reserve:${progress.reservationId}`));
        if (!held || held.kind !== "vm" || (held.retained !== true && held.expiresMs <= nowMs)) throw new Error("allocation reservation expired");
        await storage.put(`reserve:${progress.reservationId}`, { ...held, retained: true });
      }
      await storage.put(storageKey, {
        ...record,
        progress,
        expiresMs: progress.phase === "done" || progress.phase === "snapshotDone" ? Math.max(record.expiresMs, nowMs + IDEMPOTENCY_TTL_MS) : record.expiresMs,
        leaseUntilMs: progress.phase === "done" || progress.phase === "snapshotDone" ? nowMs : nowMs + IDEMPOTENCY_LEASE_MS,
    });
    });
  }

  /**
   * Ends a claim whose request failed. A key with no progress is forgotten so
   * the client can retry it; a fork that kept a snapshot stays resumable.
   */
  async abandon(key: string, nowMs: number): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const storageKey = `idem:${key}`;
      const record = checked(isRecord, await storage.get(storageKey));
      if (record === undefined) return;
      if (record.progress.phase === "pending") await storage.delete(storageKey);
      else await storage.put(storageKey, { ...record, leaseUntilMs: nowMs });
    });
  }

  /**
   * A named lock with a lease (mesh M4: one writer per mesh). Taken when free,
   * expired, or already held by `holder`; the lease bounds how long a holder
   * that died blocks the next one.
   */
  async lock(key: string, holder: string, leaseMs: number, nowMs: number): Promise<boolean> {
    const storageKey = `lock:${key}`;
    const held = checked(isLock, await this.storage.get(storageKey));
    if (held !== undefined && held.untilMs > nowMs && held.holder !== holder) return false;
    await this.storage.put(storageKey, { holder, untilMs: nowMs + leaseMs });
    return true;
  }

  /** Releases the lock when `holder` still holds it. */
  async unlock(key: string, holder: string): Promise<void> {
    const storageKey = `lock:${key}`;
    const held = checked(isLock, await this.storage.get(storageKey));
    if (held !== undefined && held.holder === holder) await this.storage.delete(storageKey);
  }

  /** Drops a bounded number of expired idempotency records. */
  private async sweep(storage: LedgerStorage, nowMs: number): Promise<void> {
    const records = await storage.list({ prefix: "idem:", limit: 64 });
    for (const [key, value] of records) {
      const record = checked(isRecord, value);
      if (record !== undefined && record.progress.phase !== "creating" && record.expiresMs <= nowMs) await storage.delete(key);
    }
  }
}

/** A LedgerStorage in memory, for tests and local tools. */
export function memoryLedgerStorage(): LedgerStorage {
  const values = new Map<string, unknown>();
  let serial = Promise.resolve();
  const view = (read: (key: string) => unknown, write: (key: string, value: unknown) => void, remove: (key: string) => boolean, entries: () => Map<string, unknown>, atomic: LedgerStorage["transaction"]): LedgerStorage => ({
    transaction: atomic,
    get: async (key) => structuredClone(read(key)),
    put: async (key, value) => {
      write(key, structuredClone(value));
    },
    delete: async (key) => remove(key),
    list: async (options) => {
      const out = new Map<string, unknown>();
      const all = entries();
      for (const key of [...all.keys()].sort()) {
        if (!key.startsWith(options.prefix)) continue;
        out.set(key, structuredClone(all.get(key)));
        if (options.limit !== undefined && out.size >= options.limit) break;
      }
      return out;
    },
  });
  const transaction: LedgerStorage["transaction"] = (run) => {
    const work = serial.then(async () => {
      const writes = new Map<string, unknown>(), removed = new Set<string>();
      const entries = () => { const result = new Map(values); for (const key of removed) result.delete(key); for (const [k, v] of writes) result.set(k, v); return result; };
      const staged: LedgerStorage = view((key) => removed.has(key) ? undefined : writes.has(key) ? writes.get(key) : values.get(key),
        (key, value) => { writes.set(key, value); removed.delete(key); }, (key) => { const had = entries().has(key); writes.delete(key); removed.add(key); return had; }, entries,
        (nested) => nested(staged));
      const result = await run(staged);
      for (const key of removed) values.delete(key);
      for (const [key, value] of writes) values.set(key, value);
      return result;
    });
    serial = work.then(() => undefined, () => undefined);
    return work;
  };
  return view((key) => values.get(key), (key, value) => { values.set(key, value); }, (key) => values.delete(key), () => new Map(values), transaction);
}
