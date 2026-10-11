/**
 * Per-tenant rate limits, create reservations (quota) and idempotency keys, as
 * an Effect service. The live layer talks to one Durable Object per tenant;
 * the memory layer runs the same ledger in process for tests.
 */
import { Context, Data, Effect, Layer, Schema } from "effect";
import type { TenantId } from "../lib/ids.ts";
import type { TenantLimitsObject } from "./durable-object.ts";
import {
  IdempotencyBegin,
  memoryLedgerStorage,
  RateDecision,
  ReserveDecision,
  TenantLedger,
  type IdempotencyProgress,
  type RateClass,
  type RateRule,
} from "./ledger.ts";

/** The limits store could not be reached; the request is refused rather than let through. */
export class LimitsUnavailable extends Data.TaggedError("LimitsUnavailable")<{ readonly cause: unknown }> {}

export interface TenantLimitsService {
  readonly rate: (tenantId: TenantId, rateClass: RateClass, rule: RateRule) => Effect.Effect<RateDecision, LimitsUnavailable>;
  readonly reserve: (tenantId: TenantId, kind: string, limit: number, liveCount: number) => Effect.Effect<ReserveDecision, LimitsUnavailable>;
  readonly release: (tenantId: TenantId, reservationId: string) => Effect.Effect<void>;
  readonly begin: (tenantId: TenantId, key: string, fingerprint: string) => Effect.Effect<IdempotencyBegin, LimitsUnavailable>;
  readonly advance: (tenantId: TenantId, key: string, progress: IdempotencyProgress) => Effect.Effect<void, LimitsUnavailable>;
  readonly abandon: (tenantId: TenantId, key: string) => Effect.Effect<void>;
  /** Takes the tenant-scoped lock `key` for `holder` for `leaseMs`; false while another holder has it. */
  readonly lock: (tenantId: TenantId, key: string, holder: string, leaseMs: number) => Effect.Effect<boolean, LimitsUnavailable>;
  /** Releases the lock if `holder` holds it; best effort (the lease ends it otherwise). */
  readonly unlock: (tenantId: TenantId, key: string, holder: string) => Effect.Effect<void>;
}

export class TenantLimits extends Context.Tag("cmux-vm/TenantLimits")<TenantLimits, TenantLimitsService>() {}

/** The ledger operations, whether a Durable Object stub or an in-process ledger. */
interface LedgerHandle {
  rate(rateClass: RateClass, rule: RateRule, nowMs: number): Promise<RateDecision>;
  reserve(kind: string, limit: number, liveCount: number, nowMs: number, reservationId: string): Promise<ReserveDecision>;
  release(reservationId: string): Promise<void>;
  begin(key: string, fingerprint: string, nowMs: number): Promise<IdempotencyBegin>;
  advance(key: string, progress: IdempotencyProgress, nowMs: number): Promise<void>;
  abandon(key: string, nowMs: number): Promise<void>;
  lock(key: string, holder: string, leaseMs: number, nowMs: number): Promise<boolean>;
  unlock(key: string, holder: string): Promise<void>;
}

const makeService = (ledgerFor: (tenantId: TenantId) => LedgerHandle): TenantLimitsService => {
  const call = <A>(run: (ledger: LedgerHandle, nowMs: number) => Promise<A>) => (tenantId: TenantId) =>
    Effect.flatMap(Effect.clockWith((clock) => clock.currentTimeMillis), (nowMs) =>
      Effect.tryPromise({ try: () => run(ledgerFor(tenantId), nowMs), catch: (cause) => new LimitsUnavailable({ cause }) }),
    );
  return {
    rate: (tenantId, rateClass, rule) => call((ledger, now) => ledger.rate(rateClass, rule, now))(tenantId),
    reserve: (tenantId, kind, limit, liveCount) =>
      call((ledger, now) => ledger.reserve(kind, limit, liveCount, now, crypto.randomUUID()))(tenantId),
    // Releases are best effort: an unreleased reservation lapses on its own.
    release: (tenantId, reservationId) => call((ledger) => ledger.release(reservationId))(tenantId).pipe(Effect.ignore),
    begin: (tenantId, key, fingerprint) => call((ledger, now) => ledger.begin(key, fingerprint, now))(tenantId),
    advance: (tenantId, key, progress) => call((ledger, now) => ledger.advance(key, progress, now))(tenantId),
    // An unabandoned claim lapses after its lease.
    abandon: (tenantId, key) => call((ledger, now) => ledger.abandon(key, now))(tenantId).pipe(Effect.ignore),
    lock: (tenantId, key, holder, leaseMs) => call((ledger, now) => ledger.lock(key, holder, leaseMs, now))(tenantId),
    unlock: (tenantId, key, holder) => call((ledger) => ledger.unlock(key, holder))(tenantId).pipe(Effect.ignore),
  };
};

/** RPC results cross a serialization boundary; decode them instead of trusting their type. */
const decoded =
  <A, I>(schema: Schema.Schema<A, I>) =>
  async (result: Promise<unknown>): Promise<A> =>
    Schema.decodeUnknownSync(schema)(await result);

/** Live: one Durable Object per tenant, addressed by tenant id. */
export const durableObjectLimitsLayer = (namespace: DurableObjectNamespace<TenantLimitsObject>): Layer.Layer<TenantLimits> =>
  Layer.succeed(
    TenantLimits,
    makeService((tenantId): LedgerHandle => {
      const stub = namespace.get(namespace.idFromName(tenantId));
      return {
        rate: (rateClass, rule, nowMs) => decoded(RateDecision)(stub.rate(rateClass, rule, nowMs)),
        reserve: (kind, limit, liveCount, nowMs, reservationId) =>
          decoded(ReserveDecision)(stub.reserve(kind, limit, liveCount, nowMs, reservationId)),
        release: async (reservationId) => {
          await stub.release(reservationId);
        },
        begin: (key, fingerprint, nowMs) => decoded(IdempotencyBegin)(stub.begin(key, fingerprint, nowMs)),
        advance: async (key, progress, nowMs) => {
          await stub.advance(key, progress, nowMs);
        },
        abandon: async (key, nowMs) => {
          await stub.abandon(key, nowMs);
        },
        lock: (key, holder, leaseMs, nowMs) => decoded(Schema.Boolean)(stub.lock(key, holder, leaseMs, nowMs)),
        unlock: async (key, holder) => {
          await stub.unlock(key, holder);
        },
      };
    }),
  );

/** In process: the same ledger over memory, one per tenant. */
export const memoryLimitsLayer = (): Layer.Layer<TenantLimits> => {
  const ledgers = new Map<string, TenantLedger>();
  return Layer.succeed(
    TenantLimits,
    makeService((tenantId) => {
      const existing = ledgers.get(tenantId);
      if (existing !== undefined) return existing;
      const ledger = new TenantLedger(memoryLedgerStorage());
      ledgers.set(tenantId, ledger);
      return ledger;
    }),
  );
};
