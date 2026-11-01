/**
 * Per-tenant rate limits, create reservations (quota) and idempotency keys, as
 * an Effect service. The live layer talks to one Durable Object per tenant;
 * the memory layer runs the same ledger in process for tests.
 */
import { SnapshotCaptureResult, type SnapshotCaptureCommand } from "./snapshot-capture.ts";
import { MeshCreationResult, type MeshCreationCommand } from "./mesh-creation.ts";
import { Context, Data, Effect, Layer, Schema } from "effect";
import { GeneratedCreationPage, type GeneratedCreation } from "../domain/generated-creation.ts";
import type { TenantId } from "../lib/ids.ts";
import type { TenantLimitsObject } from "./durable-object.ts";
import {
  CancelCreationDecision,
  IdempotencyBegin,
  IdempotencyRecord,
  memoryLedgerStorage,
  RateDecision,
  ReserveDecision,
  TenantLedger,
  type IdempotencyProgress,
  type LedgerStorage,
  type RateClass,
  type RateRule,
} from "./ledger.ts";

/** The limits store could not be reached; the request is refused rather than let through. */
export class LimitsUnavailable extends Data.TaggedError("LimitsUnavailable")<{ readonly cause: unknown }> {}

export interface TenantLimitsService {
  readonly meshCreation: (tenantId: TenantId, command: MeshCreationCommand) => Effect.Effect<MeshCreationResult, LimitsUnavailable>;
  readonly quarantineForkClaim: (tenantId: TenantId, key: string) => Effect.Effect<boolean, LimitsUnavailable>;
  readonly snapshotCapture: (tenantId: TenantId, command: SnapshotCaptureCommand) => Effect.Effect<SnapshotCaptureResult, LimitsUnavailable>;
  readonly beginCreateSend: (tenantId: TenantId, key: string, vmId: string, token: string) => Effect.Effect<boolean, LimitsUnavailable>;
  readonly settleAbsentCancellation: (tenantId: TenantId, key: string, vmId: string) => Effect.Effect<boolean, LimitsUnavailable>;
  readonly readmitCreation: (tenantId: TenantId, key: string, vmId: string, limit: number, liveCount: number) => Effect.Effect<"readmitted" | "over_quota" | "none", LimitsUnavailable>;
  readonly rejectCreateSend: (tenantId: TenantId, key: string, vmId: string, token: string) => Effect.Effect<void, LimitsUnavailable>;
  readonly creationActive: (tenantId: TenantId, key: string, vmId: string) => Effect.Effect<boolean, LimitsUnavailable>;
  readonly cancelCreation: (tenantId: TenantId, key: string, vmId: string) => Effect.Effect<CancelCreationDecision, LimitsUnavailable>;
  readonly settleCancellation: (tenantId: TenantId, key: string, vmId: string) => Effect.Effect<void, LimitsUnavailable>;
  readonly inspect: (tenantId: TenantId, key: string) => Effect.Effect<IdempotencyRecord | null, LimitsUnavailable>;
  readonly settleCreation: (tenantId: TenantId, key: string, vmId: string) => Effect.Effect<void, LimitsUnavailable>;
  readonly creationReservation: (tenantId: TenantId, key: string, vmId: string) => Effect.Effect<string | null, LimitsUnavailable>;
  readonly rate: (tenantId: TenantId, rateClass: RateClass, rule: RateRule) => Effect.Effect<RateDecision, LimitsUnavailable>;
  readonly reserve: (tenantId: TenantId, kind: string, limit: number, liveCount: number) => Effect.Effect<ReserveDecision, LimitsUnavailable>;
  readonly release: (tenantId: TenantId, reservationId: string) => Effect.Effect<void>;
  readonly listGenerated: (tenantId: TenantId, scope: string, cursor: string | undefined, limit: number, pending?: boolean) => Effect.Effect<GeneratedCreationPage, LimitsUnavailable>;
  readonly begin: (tenantId: TenantId, key: string, fingerprint: string, clientFingerprint?: string, generated?: GeneratedCreation) => Effect.Effect<IdempotencyBegin, LimitsUnavailable>;
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
  meshCreation(command: MeshCreationCommand, nowMs: number): Promise<MeshCreationResult>;
  quarantineForkClaim(key: string, nowMs: number): Promise<boolean>;
  snapshotCapture(command: SnapshotCaptureCommand, nowMs: number): Promise<SnapshotCaptureResult>;
  beginCreateSend(key: string, vmId: string, token: string, nowMs: number): Promise<boolean>;
  settleAbsentCancellation(key: string, vmId: string, nowMs: number): Promise<boolean>;
  readmitCreation(key: string, vmId: string, limit: number, liveCount: number, nowMs: number): Promise<"readmitted" | "over_quota" | "none">;
  rejectCreateSend(key: string, vmId: string, token: string): Promise<boolean>;
  creationActive(key: string, vmId: string): Promise<boolean>;
  cancelCreation(key: string, vmId: string): Promise<CancelCreationDecision>;
  settleCancellation(key: string, vmId: string): Promise<boolean>;
  inspect(key: string): Promise<IdempotencyRecord | null>;
  settleCreation(key: string, vmId: string, nowMs: number): Promise<void>;
  creationReservation(key: string, vmId: string): Promise<string | null>;
  rate(rateClass: RateClass, rule: RateRule, nowMs: number): Promise<RateDecision>;
  reserve(kind: string, limit: number, liveCount: number, nowMs: number, reservationId: string): Promise<ReserveDecision>;
  release(reservationId: string): Promise<void>;
  listGenerated(scope: string, cursor: string | undefined, limit: number, pending?: boolean): Promise<GeneratedCreationPage>;
  begin(key: string, fingerprint: string, nowMs: number, clientFingerprint?: string, generated?: GeneratedCreation): Promise<IdempotencyBegin>;
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
  const confirmed = (value: boolean) => value ? Effect.void : Effect.fail(new LimitsUnavailable({ cause: "creation write was not confirmed" }));
  return {
    meshCreation: (tenantId, command) => call((ledger, now) => ledger.meshCreation(command, now))(tenantId).pipe(
      Effect.flatMap((value) => Schema.decodeUnknown(MeshCreationResult)(value).pipe(Effect.mapError((cause) => new LimitsUnavailable({ cause })))),
    ),
    quarantineForkClaim: (tenantId, key) => call((ledger, now) => ledger.quarantineForkClaim(key, now))(tenantId),
    snapshotCapture: (tenantId, command) => call((ledger, now) => ledger.snapshotCapture(command, now))(tenantId),
    beginCreateSend: (tenantId, key, vmId, token) => call((ledger, now) => ledger.beginCreateSend(key, vmId, token, now))(tenantId),
    settleAbsentCancellation: (tenantId, key, vmId) => call((ledger, now) => ledger.settleAbsentCancellation(key, vmId, now))(tenantId),
    readmitCreation: (tenantId, key, vmId, limit, liveCount) => call((ledger, now) => ledger.readmitCreation(key, vmId, limit, liveCount, now))(tenantId),
    rejectCreateSend: (tenantId, key, vmId, token) => call((ledger) => ledger.rejectCreateSend(key, vmId, token))(tenantId).pipe(Effect.flatMap(confirmed)),
    creationActive: (tenantId, key, vmId) => call((ledger) => ledger.creationActive(key, vmId))(tenantId),
    cancelCreation: (tenantId, key, vmId) => call((ledger) => ledger.cancelCreation(key, vmId))(tenantId),
    settleCancellation: (tenantId, key, vmId) => call((ledger) => ledger.settleCancellation(key, vmId))(tenantId).pipe(Effect.flatMap(confirmed)),
    inspect: (tenantId, key) => call((ledger) => ledger.inspect(key))(tenantId),
    settleCreation: (tenantId, key, vmId) => call((ledger, now) => ledger.settleCreation(key, vmId, now))(tenantId),
    creationReservation: (tenantId, key, vmId) => call((ledger) => ledger.creationReservation(key, vmId))(tenantId),
    rate: (tenantId, rateClass, rule) => call((ledger, now) => ledger.rate(rateClass, rule, now))(tenantId),
    reserve: (tenantId, kind, limit, liveCount) =>
      call((ledger, now) => ledger.reserve(kind, limit, liveCount, now, crypto.randomUUID()))(tenantId),
    // Releases are best effort: an unreleased reservation lapses on its own.
    release: (tenantId, reservationId) => call((ledger) => ledger.release(reservationId))(tenantId).pipe(Effect.ignore),
    listGenerated: (tenantId, scope, cursor, limit, pending) => call((ledger) => ledger.listGenerated(scope, cursor, limit, pending))(tenantId),
    begin: (tenantId, key, fingerprint, clientFingerprint, generated) => call((ledger, now) => ledger.begin(key, fingerprint, now, clientFingerprint, generated))(tenantId),
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
        meshCreation: (command, nowMs) => decoded(MeshCreationResult)(stub.meshCreation(command, nowMs)),
        quarantineForkClaim: (key, nowMs) => decoded(Schema.Boolean)(stub.quarantineForkClaim(key, nowMs)),
        snapshotCapture: (command, nowMs) => decoded(SnapshotCaptureResult)(stub.snapshotCapture(command, nowMs)),
        beginCreateSend: (key, vmId, token, nowMs) => decoded(Schema.Boolean)(stub.beginCreateSend(key, vmId, token, nowMs)),
        settleAbsentCancellation: (key, vmId, nowMs) => decoded(Schema.Boolean)(stub.settleAbsentCancellation(key, vmId, nowMs)),
        readmitCreation: (key, vmId, limit, liveCount, nowMs) => decoded(Schema.Literal("readmitted", "over_quota", "none"))(stub.readmitCreation(key, vmId, limit, liveCount, nowMs)),
        rejectCreateSend: (key, vmId, token) => decoded(Schema.Boolean)(stub.rejectCreateSend(key, vmId, token)),
        creationActive: (key, vmId) => decoded(Schema.Boolean)(stub.creationActive(key, vmId)),
        cancelCreation: (key, vmId) => decoded(CancelCreationDecision)(stub.cancelCreation(key, vmId)),
        settleCancellation: (key, vmId) => decoded(Schema.Boolean)(stub.settleCancellation(key, vmId)),
        inspect: (key) => decoded(Schema.NullOr(IdempotencyRecord))(stub.inspect(key)),
        settleCreation: async (key, vmId, nowMs) => {
          if (!await decoded(Schema.Boolean)(stub.settleCreation(key, vmId, nowMs))) throw new Error("allocation settlement was not confirmed");
        },
        creationReservation: (key, vmId) => decoded(Schema.NullOr(Schema.String))(stub.creationReservation(key, vmId)),
        rate: (rateClass, rule, nowMs) => decoded(RateDecision)(stub.rate(rateClass, rule, nowMs)),
        reserve: (kind, limit, liveCount, nowMs, reservationId) =>
          decoded(ReserveDecision)(stub.reserve(kind, limit, liveCount, nowMs, reservationId)),
        release: async (reservationId) => {
          await stub.release(reservationId);
        },
        listGenerated: (scope, cursor, limit, pending) => decoded(GeneratedCreationPage)(stub.listGenerated(scope, cursor, limit, pending)),
        begin: (key, fingerprint, nowMs, clientFingerprint, generated) => decoded(IdempotencyBegin)(stub.begin(key, fingerprint, nowMs, clientFingerprint, generated)),
        advance: async (key, progress, nowMs) => {
          const confirmed = await decoded(Schema.Boolean)(stub.advance(key, progress, nowMs));
          if (!confirmed) throw new Error("allocation journal write was not confirmed");
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
export const memoryLimitsLayer = (storageFor: (tenantId: TenantId) => LedgerStorage = () => memoryLedgerStorage()): Layer.Layer<TenantLimits> => {
  const ledgers = new Map<string, TenantLedger>();
  return Layer.succeed(
    TenantLimits,
    makeService((tenantId) => {
      const existing = ledgers.get(tenantId);
      if (existing !== undefined) return existing;
      const ledger = new TenantLedger(storageFor(tenantId));
      ledgers.set(tenantId, ledger);
      return ledger;
    }),
  );
};
