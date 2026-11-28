/**
 * One tenant's counters: rate-limit buckets, in-flight create reservations and
 * idempotency records. Pure logic over a small key-value storage, so the
 * Durable Object (one per tenant, which serializes every call) and the tests
 * run the same code.
 *
 * Nothing here holds a secret, a command or a provider id: idempotency records
 * keep request/provider digests, public creation intent and public cmux ids.
 */
import { SnapshotCapture, SnapshotKeyFence, snapshotCapture, type SnapshotCaptureCommand, type SnapshotCaptureResult } from "./snapshot-capture.ts";
import { pendingCreations } from "./pending-creations.ts";
import { Schema } from "effect";
import { GeneratedCreation, GeneratedCreationPage } from "../domain/generated-creation.ts";
import { VmCreationReceipt } from "../api/creations.ts";
import { SnapshotId, VmId } from "../lib/ids.ts";
import { RetainedVmCreation } from "../domain/vm-creation.ts";
import { deleteMany, getMany, Reservation, type LedgerStorage } from "./storage.ts";
import { meshCreation, type MeshCreationCommand, type MeshCreationResult } from "./mesh-creation.ts";
import { admitAgentSlot, bindAgentCreation, forgetAgentVm, settleAgentSlot, type AgentSlotOutcome } from "./agent-slots.ts";
export type { LedgerStorage } from "./storage.ts";

/** The subset of Durable Object storage the ledger uses. Values come back untyped and are checked on read. */

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
 * Progress a create or fork made under one idempotency key: claimed (no VM
 * send yet), pending (legacy unknown outcome), capturing (a fork's assigned destination and intermediate),
 * creating (durable allocation/context and retained quota),
 * snapshotted (a fork took its snapshot, public id, but
 * has not created the VM), done (the VM, public id), snapshotDone (a snapshot
 * create finished, public snapshot id).
 */
const Creation = {
  vmId: Schema.String, reservationId: Schema.String, context: Schema.String, createdBy: Schema.String,
  snapshotId: Schema.optional(Schema.String), intent: Schema.optional(RetainedVmCreation),
  dispatch: Schema.optional(Schema.Struct({ state: Schema.Literal("ready", "sent", "rejected"), token: Schema.String, at: Schema.optional(Schema.Number) })),
  cancelRequested: Schema.optional(Schema.Boolean),
};
export const ForkCaptureProgress = Schema.Struct({
  phase: Schema.Literal("capturing"), vmId: VmId, sourceVmId: VmId, snapshotId: SnapshotId,
  captureKey: Schema.String, reservationId: Schema.String, createdBy: Schema.String,
  createdAt: Schema.String, receipt: VmCreationReceipt,
  cancelRequested: Schema.optional(Schema.Boolean), cancelled: Schema.optional(Schema.Boolean),
});
export type ForkCaptureProgress = typeof ForkCaptureProgress.Type;
const Progress = Schema.Union(
  ForkCaptureProgress,
  Schema.Struct({ phase: Schema.Literal("claimed") }),
  Schema.Struct({ phase: Schema.Literal("pending") }),
  Schema.Struct({ phase: Schema.Literal("creating"), ...Creation }),
  Schema.Struct({ phase: Schema.Literal("cancelled"), ...Creation }),
  Schema.Struct({ phase: Schema.Literal("snapshotted"), snapshotId: Schema.String }),
  Schema.Struct({ phase: Schema.Literal("done"), vmId: Schema.String }),
  Schema.Struct({ phase: Schema.Literal("snapshotDone"), snapshotId: Schema.String }),
);
export const CancelCreationDecision = Schema.Literal("accepted", "finished", "legacy");
export type CancelCreationDecision = typeof CancelCreationDecision.Type;
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

export const IdempotencyRecord = Schema.Struct({
  fingerprint: Schema.String,
  /** Stable admitted client request, retained when an operator image leaves the catalog. Digest only. */
  clientFingerprint: Schema.optional(Schema.String),
  generated: Schema.optional(GeneratedCreation),
  progress: Progress,
  /** While pending: when the claim lapses if its request died. */
  leaseUntilMs: Schema.Number,
  expiresMs: Schema.Number,
});

export type IdempotencyRecord = typeof IdempotencyRecord.Type;

export const RetainedCreationSlot = Schema.Struct({ key: Schema.String, vmId: Schema.String, startedMs: Schema.Number, cancelRequested: Schema.Boolean });
export type RetainedCreationSlot = typeof RetainedCreationSlot.Type;
const isRetainedSlot = Schema.is(Schema.Struct({ ...Reservation.fields, vmCreation: Schema.optional(Schema.Unknown) }));
const isSlotLink = Schema.is(Schema.Struct({ key: Schema.String, vmId: Schema.String }));


const isBucket = Schema.is(Bucket);
const isRecord = Schema.is(IdempotencyRecord);
const GeneratedIndex = Schema.Struct({ key: Schema.String, generated: GeneratedCreation });
const isGeneratedIndex = Schema.is(GeneratedIndex);
const generatedPrefix = (scope: string) => `generated:${encodeURIComponent(scope)}:`;
// An older ledger rejects this progress tag instead of expiring or rewriting a generated operation.
const GeneratedRecord = Schema.Struct({
  ...IdempotencyRecord.fields,
  generated: GeneratedCreation,
  progress: Schema.Struct({ phase: Schema.Literal("generated"), value: Progress }),
});
const isGeneratedRecord = Schema.is(GeneratedRecord);
const readRecord = (value: unknown): IdempotencyRecord | undefined => isGeneratedRecord(value)
  ? { ...value, progress: value.progress.value }
  : checked(isRecord, value);
/**
 * Whether the creation under `key` provably sent nothing to the provider: its intent is still `creating` with a
 * dispatch that never left `ready` (only beginCreateSend moves it to `sent`) or that the provider rejected. A legacy
 * intent with no dispatch receipt, a send whose outcome is unknown, and a missing record all answer false.
 */
export const creationNeverSent = async (storage: LedgerStorage, key: string): Promise<boolean> => {
  const p = readRecord(await storage.get(`idem:${key}`))?.progress;
  return p?.phase === "creating" && (p.dispatch?.state === "ready" || p.dispatch?.state === "rejected");
};
/** Decodes a stored idempotency record (plain or generated); exported for the scan oracle in test/support. */
export const readIdempotencyRecord = readRecord;
const putRecord = (storage: LedgerStorage, key: string, record: IdempotencyRecord) => storage.put(key,
  record.generated === undefined ? record : { ...record, progress: { phase: "generated", value: record.progress } },
);

const isReservation = Schema.is(Reservation);

const Lock = Schema.Struct({ holder: Schema.String, untilMs: Schema.Number });
const isLock = Schema.is(Lock);
/** A mesh's apply coverage: `wanted` counts the changes that need an apply, `applied` is the highest one an apply has read. */
const Coverage = Schema.Struct({ wanted: Schema.Number, applied: Schema.Number });
const isCoverage = Schema.is(Coverage);

/**
 * Whether two journaled values are the same value, whatever order their keys are in. A resumed create reads its
 * intent back through the Durable Object RPC decoded in the schema's field order, not the order the handler built it
 * in, so comparing JSON.stringify output read the same intent as changed: on staging every retry of a create whose
 * send timed out failed as "allocation intent changed" (an anonymous persistCreateIntent 503) until create_overdue.
 */
const canonical = (value: unknown): string => JSON.stringify(value, (_key, v: unknown) =>
  v !== null && typeof v === "object" && !Array.isArray(v)
    ? Object.fromEntries(Object.entries(v).filter(([, x]) => x !== undefined).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
    : v);
const sameValue = (a: unknown, b: unknown): boolean => canonical(a) === canonical(b);

/** A stored value of the wrong shape (from an older version) reads as absent. */
const checked = <T>(guard: (value: unknown) => value is T, value: unknown): T | undefined => (guard(value) ? value : undefined);

/** Idempotency records live for a day, as clients retry within minutes to hours. */
export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;
/**
 * A pending claim whose request died (isolate recycled, connection cut, deploy)
 * is released this long after its last heartbeat, so a same-key resend can take
 * it over instead of getting "still running" for the old 10 minutes. A live
 * request renews it every IDEMPOTENCY_HEARTBEAT_MS (and on each `advance`), so
 * it never loses its claim however long the create or fork runs.
 */
export const IDEMPOTENCY_LEASE_MS = 90 * 1000;
export const IDEMPOTENCY_HEARTBEAT_MS = 20 * 1000;
/** An ordinary reservation expires after this long; an uncertain allocation retains its slot. */
export const RESERVATION_TTL_MS = 5 * 60 * 1000;
/**
 * After this long, a send whose outcome was never learned and whose exact slug still answers 404 made nothing:
 * twice the 120 s create timeout plus provider propagation. Only then may it be resent or its cancellation settle.
 */
export const CREATE_SEND_GRACE_MS = 10 * 60 * 1000;
/**
 * After this long, a send whose outcome was never learned may be sent again under the same slug, once the caller's
 * exact-slug read answered 404. The provider refuses a second VM at a slug ("409 CONFLICT: that slug is already used by
 * another VM in your account"; nothing here passes `reassignSlug`), so a resend can never make a second VM: either the
 * first send made nothing and this one creates it, or it answers 409 and the read after it adopts the first send's VM.
 * It is the 120 s create timeout plus 30 s, so no two of this key's sends are open at once, and it sits well inside the
 * platform's 5-minute create retry window (cmux-platform `CREATE_RETRY_WINDOW_MS`). Before this, the resend waited the
 * whole CREATE_SEND_GRACE_MS: one provider timeout failed every retry of that create (staging vm_9fca061251a7f47ec504,
 * 2026-11-26: 1 timed-out send, then 7 refused retries and cloud.provider.unavailable). Settling a cancellation as
 * "nothing was made" still waits CREATE_SEND_GRACE_MS: no provider answer backs that one.
 */
export const CREATE_RESEND_AFTER_MS = 150 * 1000;
type Dispatch = { readonly state: "ready" | "sent" | "rejected"; readonly at?: number | undefined };
const sentAgo = (dispatch: Dispatch, nowMs: number | undefined, ms: number) =>
  dispatch.state !== "sent" || (nowMs !== undefined && dispatch.at !== undefined && nowMs - dispatch.at >= ms);
const sendSettled = (dispatch: Dispatch, nowMs: number | undefined) => sentAgo(dispatch, nowMs, CREATE_SEND_GRACE_MS);
const sendResendable = (dispatch: Dispatch, nowMs: number | undefined) => sentAgo(dispatch, nowMs, CREATE_RESEND_AFTER_MS);

/**
 * Takes lock `key` for `holder` inside the caller's transaction. Every read-modify-write of a lock or a coverage key runs
 * in one ledger transaction: a Durable Object's input gate already kept two calls from interleaving between the read
 * and the write, but the in-memory ledger has no gate, and there 50 concurrent writers all took one lock.
 */
const takeLock = async (storage: LedgerStorage, key: string, holder: string, leaseMs: number, nowMs: number): Promise<boolean> => {
  const storageKey = `lock:${key}`;
  const held = checked(isLock, await storage.get(storageKey));
  if (held !== undefined && held.untilMs > nowMs && held.holder !== holder) return false;
  await storage.put(storageKey, { holder, untilMs: nowMs + leaseMs });
  return true;
};

export class TenantLedger {
  constructor(private readonly storage: LedgerStorage) {}

  meshCreation(command: MeshCreationCommand, nowMs: number): Promise<MeshCreationResult> { return meshCreation(this.storage, command, nowMs); }
  admitAgentSlot(agent: string, limit: number, ownedVmIds: ReadonlyArray<string>, nowMs: number, slotId: string): Promise<boolean> { return admitAgentSlot(this.storage, agent, limit, ownedVmIds, nowMs, slotId, creationNeverSent); }
  settleAgentSlot(agent: string, slotId: string, outcome: AgentSlotOutcome, nowMs: number): Promise<void> { return settleAgentSlot(this.storage, agent, slotId, outcome, nowMs); }
  bindAgentCreation(agent: string, creationKey: string, vmId: string, nowMs: number): Promise<void> { return bindAgentCreation(this.storage, agent, creationKey, vmId, nowMs); }
  forgetAgentVm(vmId: string, creationKey: string | null): Promise<void> { return forgetAgentVm(this.storage, vmId, creationKey); }

  snapshotCapture(command: SnapshotCaptureCommand, nowMs: number): Promise<SnapshotCaptureResult> { return snapshotCapture(this.storage, command, nowMs); }

  /** Read only: inspecting an expired record never drops a retained allocation. */
  async inspect(key: string): Promise<IdempotencyRecord | null> {
    return readRecord(await this.storage.get(`idem:${key}`)) ?? null;
  }

  /** A legacy fork claim may already have sent a snapshot without retaining its identity. */
  async quarantineForkClaim(key: string, nowMs: number): Promise<boolean> {
    return this.storage.transaction(async (storage) => {
      const record = readRecord(await storage.get(`idem:${key}`));
      if (record?.progress.phase === "pending") return true;
      if (record?.progress.phase !== "claimed" || record.leaseUntilMs > nowMs) return false;
      await putRecord(storage, `idem:${key}`, { ...record, progress: { phase: "pending" }, leaseUntilMs: 0 });
      return true;
    });
  }

  /** Called only after ownership has committed, including a lost completion receipt. */
  async settleCreation(key: string, vmId: string, nowMs: number): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const record = readRecord(await storage.get(`idem:${key}`));
      if (record?.progress.phase === "done" && record.progress.vmId === vmId) return;
      if (record?.progress.phase !== "creating" || record.progress.vmId !== vmId || record.progress.cancelRequested === true) throw new Error("allocation intent changed");
      await storage.delete(`reserve:${record.progress.reservationId}`);
      await putRecord(storage, `idem:${key}`, { ...record, progress: { phase: "done", vmId }, leaseUntilMs: nowMs, expiresMs: Math.max(record.expiresMs, nowMs + IDEMPOTENCY_TTL_MS) });
    });
  }

  /**
   * One potentially allocating provider send at a time. An unknown outcome reopens this gate only after
   * CREATE_RESEND_AFTER_MS, and the caller sends only after its exact-slug lookup found nothing.
   */
  async beginCreateSend(key: string, vmId: string, token: string, nowMs?: number): Promise<boolean> {
    return this.storage.transaction(async (storage) => {
      const record = readRecord(await storage.get(`idem:${key}`));
      if (record === undefined) return false;
      const p = record.progress;
      if (p.phase !== "creating" || p.vmId !== vmId || p.cancelRequested === true || p.dispatch === undefined || !sendResendable(p.dispatch, nowMs)) return false;
      await putRecord(storage, `idem:${key}`, { ...record, progress: { ...p, dispatch: { state: "sent", token, ...(nowMs === undefined ? {} : { at: nowMs }) } } });
      return true;
    });
  }

  /** Only a documented provider rejection proves that this exact send allocated nothing. */
  async rejectCreateSend(key: string, vmId: string, token: string): Promise<boolean> {
    return this.storage.transaction(async (storage) => {
      const record = readRecord(await storage.get(`idem:${key}`));
      if (record === undefined) return false;
      const p = record.progress;
      if (p.phase !== "creating" || p.vmId !== vmId || p.dispatch?.state !== "sent" || p.dispatch.token !== token) return false;
      // Nothing was made, so its slot is free; a retry with this key is readmitted under quota (readmitCreation).
      await storage.delete(`reserve:${p.reservationId}`);
      await putRecord(storage, `idem:${key}`, { ...record, progress: { ...p, phase: p.cancelRequested === true ? "cancelled" : "creating", dispatch: { state: "rejected", token } } });
      return true;
    });
  }

  async creationActive(key: string, vmId: string): Promise<boolean> {
    const record = await this.inspect(key), p = record?.progress;
    return p?.phase === "creating" && p.vmId === vmId && p.cancelRequested !== true;
  }

  /** Monotonic fence, before any provider cleanup. Legacy sends have no trustworthy dispatch receipt. */
  async cancelCreation(key: string, vmId: string): Promise<CancelCreationDecision> {
    return this.storage.transaction(async (storage) => {
      const record = readRecord(await storage.get(`idem:${key}`));
      if (record === undefined) return "finished";
      const p = record.progress;
      if (p.phase === "cancelled" && p.vmId === vmId) return "accepted";
      if (p.phase === "capturing" && p.vmId === vmId) {
        await putRecord(storage, `idem:${key}`, { ...record, progress: { ...p, cancelRequested: true } });
        return "accepted";
      }
      if (p.phase !== "creating" || p.vmId !== vmId) return "finished";
      if (p.dispatch === undefined) return "legacy";
      const terminal = p.dispatch.state !== "sent";
      if (terminal) await storage.delete(`reserve:${p.reservationId}`);
      await putRecord(storage, `idem:${key}`, { ...record, progress: { ...p, cancelRequested: true, phase: terminal ? "cancelled" : "creating" } });
      return "accepted";
    });
  }

  /** A cancelled intent whose exact slug answered 404: settles once no send can still be allocating. */
  async settleAbsentCancellation(key: string, vmId: string, nowMs: number): Promise<boolean> {
    return this.storage.transaction(async (storage) => {
      const record = readRecord(await storage.get(`idem:${key}`));
      if (record === undefined) return false;
      const p = record.progress;
      if (p.phase === "cancelled" && p.vmId === vmId) return true;
      if (p.phase !== "creating" || p.vmId !== vmId || p.cancelRequested !== true || p.dispatch === undefined || !sendSettled(p.dispatch, nowMs)) return false;
      await storage.delete(`reserve:${p.reservationId}`);
      await putRecord(storage, `idem:${key}`, { ...record, progress: { ...p, phase: "cancelled" } });
      return true;
    });
  }

  /** A rejected send released its slot: a retry of the same intent takes one again under the same quota rule. */
  async readmitCreation(key: string, vmId: string, limit: number, liveCount: number, nowMs: number): Promise<"readmitted" | "over_quota" | "none"> {
    return this.storage.transaction(async (storage) => {
      const p = readRecord(await storage.get(`idem:${key}`))?.progress;
      if (p?.phase !== "creating" || p.vmId !== vmId || p.cancelRequested === true || p.dispatch?.state !== "rejected") return "none";
      return (await this.admit(storage, "vm", limit, liveCount, nowMs, p.reservationId, true)) ? "readmitted" : "over_quota";
    });
  }

  /** After a verified allocation is deleted and SQL has a tombstone. Never expires into another create. */
  async settleCancellation(key: string, vmId: string): Promise<boolean> {
    return this.storage.transaction(async (storage) => {
      const record = readRecord(await storage.get(`idem:${key}`));
      if (record === undefined) return false;
      const p = record.progress;
      if (p.phase === "cancelled" && p.vmId === vmId) return true;
      if (p.phase === "capturing" && p.vmId === vmId && p.cancelRequested === true) {
        const child = await storage.get(`idem:${p.captureKey}`);
        if (!(Schema.is(SnapshotKeyFence)(child) || (Schema.is(SnapshotCapture)(child) && child.intent.id === p.snapshotId && child.state === "cancelled"))) return false;
        await storage.delete(`reserve:${p.reservationId}`);
        await putRecord(storage, `idem:${key}`, { ...record, progress: { ...p, cancelled: true } });
        return true;
      }
      if (p.phase !== "creating" || p.vmId !== vmId || p.cancelRequested !== true || p.dispatch === undefined) return false;
      await storage.delete(`reserve:${p.reservationId}`);
      await putRecord(storage, `idem:${key}`, { ...record, progress: { ...p, phase: "cancelled" } });
      return true;
    });
  }

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
    return this.storage.transaction(async (storage) =>
      (await this.admit(storage, kind, limit, liveCount, nowMs, reservationId, false)) ? { ok: true, reservationId } : { ok: false });
  }

  private async admit(storage: LedgerStorage, kind: string, limit: number, liveCount: number, nowMs: number, reservationId: string, retained: boolean): Promise<boolean> {
    const live = await storage.list({ prefix: "reserve:" });
    let inFlight = 0;
    const expired: string[] = [];
    for (const [key, value] of live) {
      const reservation = checked(isReservation, value);
      if (reservation === undefined || (reservation.retained !== true && reservation.expiresMs <= nowMs)) expired.push(key);
      else if (reservation.kind === kind && key !== `reserve:${reservationId}`) inFlight += 1;
    }
    await deleteMany(storage, expired);
    if (liveCount + inFlight >= limit) return false;
    await storage.put(`reserve:${reservationId}`, { kind, expiresMs: nowMs + RESERVATION_TTL_MS, ...(retained ? { retained: true } : {}) });
    return true;
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
      const record = readRecord(await storage.get(`idem:${key}`));
      if ((record?.progress.phase !== "creating" && record?.progress.phase !== "capturing") || record.progress.vmId !== vmId) return null;
      const held = checked(isReservation, await storage.get(`reserve:${record.progress.reservationId}`));
      return held?.kind === "vm" && held.retained === true ? record.progress.reservationId : null;
    });
  }

  /** Claims `key` for a request with `fingerprint`, or reports what an earlier request with the key did. */
  async begin(key: string, fingerprint: string, nowMs: number, clientFingerprint?: string, generated?: GeneratedCreation): Promise<IdempotencyBegin> {
    return this.storage.transaction(async (storage) => {
      const storageKey = `idem:${key}`;
      const raw = await storage.get(storageKey), record = readRecord(raw);
      if (raw !== undefined && record === undefined) throw new Error("unrecognized idempotency record");
      if (record !== undefined && (record.generated !== undefined || record.expiresMs > nowMs || record.progress.phase === "creating" || record.progress.phase === "capturing" || record.progress.phase === "cancelled" || record.progress.phase === "pending")) {
        if (record.fingerprint !== fingerprint || (record.clientFingerprint !== undefined && clientFingerprint !== undefined && record.clientFingerprint !== clientFingerprint) || (generated !== undefined && !sameValue(record.generated, generated))) return { state: "mismatch" };
        // Older pending records may already have sent a provider create without retaining its ID.
        // They cannot safely become a new allocation, even after their former TTL.
        if (record.progress.phase === "pending") return { state: "in_progress" };
        if (record.progress.phase === "cancelled" || ((record.progress.phase === "creating" || record.progress.phase === "capturing") && record.progress.cancelRequested === true)) return { state: "resume", progress: record.progress };
        if (record.progress.phase === "done" || record.progress.phase === "snapshotDone") return { state: "resume", progress: record.progress };
        if (record.leaseUntilMs > nowMs) return (record.progress.phase === "creating" || record.progress.phase === "capturing") ? { state: "in_progress", progress: record.progress } : { state: "in_progress" };
        if (record.progress.phase === "snapshotted" || record.progress.phase === "creating" || record.progress.phase === "capturing") {
          await putRecord(storage, storageKey, { ...record, leaseUntilMs: nowMs + IDEMPOTENCY_LEASE_MS });
          return { state: "resume", progress: record.progress };
        }
      }
      await putRecord(storage, storageKey, {
        fingerprint,
        ...(clientFingerprint === undefined ? {} : { clientFingerprint }),
        ...(generated === undefined ? {} : { generated }),
        progress: { phase: "claimed" },
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
      const record = readRecord(await storage.get(storageKey));
      if (record === undefined) throw new Error("missing idempotency claim");
      if (record.progress.phase === "cancelled" || ((record.progress.phase === "creating" || record.progress.phase === "capturing") && record.progress.cancelRequested === true)) throw new Error("creation cancellation is fenced");
      if (record.progress.phase === "done" || record.progress.phase === "snapshotDone") {
        if (sameValue(record.progress, progress)) return;
        throw new Error("a completed idempotency record cannot change");
      }
      if (record.leaseUntilMs <= nowMs) throw new Error("idempotency claim expired");
      if (record.progress.phase === "creating") {
        const prior = record.progress;
        if (progress.phase === "creating" && (progress.vmId !== prior.vmId || progress.reservationId !== prior.reservationId || progress.context !== prior.context || progress.createdBy !== prior.createdBy || progress.snapshotId !== prior.snapshotId || !sameValue(progress.dispatch, prior.dispatch) || progress.cancelRequested !== prior.cancelRequested || (prior.intent !== undefined && !sameValue(progress.intent, prior.intent)))) throw new Error("allocation intent changed");
        if (progress.phase !== "creating" && (progress.phase !== "done" || progress.vmId !== prior.vmId)) throw new Error("allocation intent cannot be replaced");
        if (progress.phase === "done") await storage.delete(`reserve:${prior.reservationId}`);
      }
      if (record.progress.phase === "capturing") {
        const prior = record.progress;
        if (progress.phase === "capturing" ? !sameValue(progress, prior)
          : progress.phase !== "creating" || progress.vmId !== prior.vmId || progress.reservationId !== prior.reservationId
            || progress.snapshotId !== prior.snapshotId || progress.createdBy !== prior.createdBy
            || !sameValue(progress.intent?.receipt, prior.receipt)) throw new Error("fork capture intent changed");
      }
      if (progress.phase === "capturing" && progress.receipt.id !== progress.vmId) throw new Error("fork destination identity changed");
      if (progress.phase === "creating" || progress.phase === "capturing") {
        const held = checked(isReservation, await storage.get(`reserve:${progress.reservationId}`));
        if (!held || held.kind !== "vm" || (held.retained !== true && held.expiresMs <= nowMs)) throw new Error("allocation reservation expired");
        await storage.put(`reserve:${progress.reservationId}`, { ...held, retained: true, vmCreation: { key, vmId: progress.vmId } });
      }
      if (record.generated !== undefined && (progress.phase === "creating" || progress.phase === "capturing" || progress.phase === "snapshotted")) {
        await storage.put(`${generatedPrefix(record.generated.scope)}${record.generated.cursor}`, { key, generated: record.generated });
      }
      await putRecord(storage, storageKey, {
        ...record,
        progress,
        expiresMs: progress.phase === "done" || progress.phase === "snapshotDone" ? Math.max(record.expiresMs, nowMs + IDEMPOTENCY_TTL_MS) : record.expiresMs,
        leaseUntilMs: progress.phase === "done" || progress.phase === "snapshotDone" ? nowMs : nowMs + IDEMPOTENCY_LEASE_MS,
      });
    });
  }

  /** Heartbeat of the request holding `key`: extends a live, unfinished claim. A lapsed claim is not revived. */
  async renew(key: string, nowMs: number): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const storageKey = `idem:${key}`;
      const record = readRecord(await storage.get(storageKey));
      if (record === undefined || record.leaseUntilMs <= nowMs) return;
      if (record.progress.phase === "done" || record.progress.phase === "snapshotDone" || record.progress.phase === "cancelled") return;
      await putRecord(storage, storageKey, { ...record, leaseUntilMs: nowMs + IDEMPOTENCY_LEASE_MS });
    });
  }

  /**
   * Ends a claim whose request failed. A key with no progress is forgotten so
   * the client can retry it; a fork that kept a snapshot stays resumable.
   */
  async abandon(key: string, nowMs: number): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const storageKey = `idem:${key}`;
      const record = readRecord(await storage.get(storageKey));
      if (record === undefined) return;
      if (record.progress.phase === "claimed") await storage.delete(storageKey);
      else await putRecord(storage, storageKey, { ...record, leaseUntilMs: nowMs });
    });
  }

  /**
   * A named lock with a lease (mesh M4: one writer per mesh). Taken when free,
   * expired, or already held by `holder`; the lease bounds how long a holder
   * that died blocks the next one.
   */
  async lock(key: string, holder: string, leaseMs: number, nowMs: number): Promise<boolean> {
    return this.storage.transaction((storage) => takeLock(storage, key, holder, leaseMs, nowMs));
  }

  /**
   * Takes lock `key` as `lock` does, unless coverage `coverageKey` has applied
   * `need` already: then it answers "covered" and takes nothing, so a writer
   * whose change another writer's apply already covered leaves the queue.
   */
  async lockUnlessCovered(key: string, holder: string, leaseMs: number, nowMs: number, coverageKey: string, need: number): Promise<"taken" | "busy" | "covered"> {
    return this.storage.transaction(async (storage) => {
      const coverage = checked(isCoverage, await storage.get(`coverage:${coverageKey}`));
      if (coverage !== undefined && coverage.applied >= need) return "covered";
      return (await takeLock(storage, key, holder, leaseMs, nowMs)) ? "taken" : "busy";
    });
  }

  /** Counts one more change that needs an apply; answers its number. */
  async coverageWant(key: string): Promise<number> {
    // One transaction from the read to the write: two wants that interleaved there would share one number, and the
    // attach left with it could be answered by an apply that never read its member row (#41517 review F1).
    return this.storage.transaction(async (storage) => {
      const storageKey = `coverage:${key}`;
      const coverage = checked(isCoverage, await storage.get(storageKey)) ?? { wanted: 0, applied: 0 };
      const wanted = coverage.wanted + 1;
      await storage.put(storageKey, { ...coverage, wanted });
      return wanted;
    });
  }

  /** The number of the latest change: an apply that reads state after this answer covers every change up to it. */
  async coverageWanted(key: string): Promise<number> {
    return checked(isCoverage, await this.storage.get(`coverage:${key}`))?.wanted ?? 0;
  }

  /** Records that an apply covering every change up to `upTo` has landed; `applied` only grows. */
  async coverageApplied(key: string, upTo: number): Promise<void> {
    // In one transaction too: a want that landed between this read and write would be overwritten and lost.
    await this.storage.transaction(async (storage) => {
      const storageKey = `coverage:${key}`;
      const coverage = checked(isCoverage, await storage.get(storageKey)) ?? { wanted: 0, applied: 0 };
      if (upTo <= coverage.applied) return;
      await storage.put(storageKey, { wanted: Math.max(coverage.wanted, upTo), applied: upTo });
    });
  }

  /** Releases the lock when `holder` still holds it. */
  async unlock(key: string, holder: string): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const storageKey = `lock:${key}`;
      const held = checked(isLock, await storage.get(storageKey));
      if (held !== undefined && held.holder === holder) await storage.delete(storageKey);
    });
  }

  /**
   * Read only: the unfinished creates `createdBy` started that still hold a retained VM slot, oldest first, at most
   * `limit`. Nothing else ever frees a slot whose request died after its send began, so a caller that can prove the
   * create is over (a CI principal past its run cap) cancels them through the ordinary verified cancellation.
   */
  async retainedCreations(createdBy: string, limit: number): Promise<ReadonlyArray<RetainedCreationSlot>> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 64) throw new Error("invalid retained creation page");
    const slots = new Set<string>();
    const links = new Map<string, string>();
    for (const [key, value] of await this.storage.list({ prefix: "reserve:" })) {
      if (!isRetainedSlot(value) || value.kind !== "vm" || value.retained !== true) continue;
      slots.add(key.slice("reserve:".length));
      if (isSlotLink(value.vmCreation)) links.set(key.slice("reserve:".length), value.vmCreation.key);
    }
    if (slots.size === 0) return [];
    // Slots retained before they carried their link: find their intents in one bounded page.
    const keys = new Set(links.values());
    if (links.size < slots.size) {
      for (const [key, value] of await this.storage.list({ prefix: "idem:", limit: 256 })) {
        const p = readRecord(value)?.progress;
        if (p?.phase === "creating" && slots.has(p.reservationId)) keys.add(key.slice("idem:".length));
      }
    }
    // One storage call per 128 intents, not one per slot: a CI principal's sweep reads every retained slot's intent.
    const records = await getMany(this.storage, [...keys].map((key) => `idem:${key}`));
    const found: RetainedCreationSlot[] = [];
    for (const key of keys) {
      const p = readRecord(records.get(`idem:${key}`))?.progress;
      if (p?.phase !== "creating" || !slots.has(p.reservationId) || p.createdBy !== createdBy || p.intent === undefined || p.dispatch === undefined) continue;
      const startedMs = p.dispatch.at ?? Date.parse(p.intent.createdAt);
      if (!Number.isFinite(startedMs)) continue;
      found.push({ key, vmId: p.vmId, startedMs, cancelRequested: p.cancelRequested === true });
    }
    return found.sort((a, b) => a.startedMs - b.startedMs).slice(0, limit);
  }

  /** Bounded, read-only scan. Cursors are domain-separated digests of random server handles. */
  async listGenerated(scope: string, cursor: string | undefined, limit: number, pending = false): Promise<GeneratedCreationPage> {
    if (pending) return pendingCreations(this.storage, scope, cursor, limit, readRecord);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100 || (cursor !== undefined && !/^[a-f0-9]{64}$/.test(cursor))) throw new Error("invalid creation page");
    const prefix = generatedPrefix(scope);
    const rows = [...await this.storage.list({ prefix, ...(cursor === undefined ? {} : { startAfter: prefix + cursor }), limit: limit + 1 })];
    const scanned = rows.slice(0, limit), items: GeneratedCreation[] = [];
    for (const [, raw] of scanned) {
      const index = checked(isGeneratedIndex, raw);
      if (index === undefined || index.generated.scope !== scope) continue;
      const record = await this.inspect(index.key);
      if (record?.generated?.key !== index.generated.key) continue;
      items.push(record.generated);
    }
    return { items, nextCursor: rows.length > limit ? scanned.at(-1)?.[0].slice(prefix.length) ?? null : null };
  }

  /** Rotate a bounded sweep so permanent operation history cannot starve ordinary expiry. */
  private async sweep(storage: LedgerStorage, nowMs: number): Promise<void> {
    const previous = await storage.get("maintenance:sweep-cursor");
    const records = await storage.list({ prefix: "idem:", ...(typeof previous === "string" ? { startAfter: previous } : {}), limit: 64 });
    for (const [key, value] of records) {
      const record = readRecord(value);
      if (record !== undefined && record.generated === undefined && record.progress.phase !== "creating" && record.progress.phase !== "capturing" && record.progress.phase !== "cancelled" && record.progress.phase !== "pending" && record.expiresMs <= nowMs) await storage.delete(key);
    }
    if (records.size === 64) await storage.put("maintenance:sweep-cursor", [...records.keys()].at(-1));
    else await storage.delete("maintenance:sweep-cursor");
  }

}

/** A LedgerStorage in memory, for tests and local tools. */
export function memoryLedgerStorage(): LedgerStorage {
  const values = new Map<string, unknown>();
  let serial = Promise.resolve();
  const view = (read: (key: string) => unknown, write: (key: string, value: unknown) => void, remove: (key: string) => boolean, entries: () => Map<string, unknown>, atomic: LedgerStorage["transaction"]): LedgerStorage => ({
    transaction: atomic,
    get: async (key) => structuredClone(read(key)),
    getMany: async (keys) => {
      const out = new Map<string, unknown>();
      for (const key of keys) { const value = read(key); if (value !== undefined) out.set(key, structuredClone(value)); }
      return out;
    },
    deleteMany: async (keys) => keys.filter((key) => remove(key)).length,
    put: async (key, value) => {
      write(key, structuredClone(value));
    },
    delete: async (key) => remove(key),
    list: async (options) => {
      const out = new Map<string, unknown>();
      const all = entries();
      for (const key of [...all.keys()].sort()) {
        if (!key.startsWith(options.prefix) || (options.startAfter !== undefined && key <= options.startAfter)) continue;
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
