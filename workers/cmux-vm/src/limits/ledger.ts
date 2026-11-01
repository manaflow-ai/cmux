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
import { Reservation, type LedgerStorage } from "./storage.ts";
import { meshCreation, type MeshCreationCommand, type MeshCreationResult } from "./mesh-creation.ts";
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
const putRecord = (storage: LedgerStorage, key: string, record: IdempotencyRecord) => storage.put(key,
  record.generated === undefined ? record : { ...record, progress: { phase: "generated", value: record.progress } },
);

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
/**
 * After this long, a send whose outcome was never learned and whose exact slug still answers 404 made nothing:
 * twice the 120 s create timeout plus provider propagation. Only then may it be resent or its cancellation settle.
 */
export const CREATE_SEND_GRACE_MS = 10 * 60 * 1000;
type Dispatch = { readonly state: "ready" | "sent" | "rejected"; readonly at?: number | undefined };
const sendSettled = (dispatch: Dispatch, nowMs: number | undefined) =>
  dispatch.state !== "sent" || (nowMs !== undefined && dispatch.at !== undefined && nowMs - dispatch.at >= CREATE_SEND_GRACE_MS);

export class TenantLedger {
  constructor(private readonly storage: LedgerStorage) {}

  meshCreation(command: MeshCreationCommand, nowMs: number): Promise<MeshCreationResult> { return meshCreation(this.storage, command, nowMs); }

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
   * CREATE_SEND_GRACE_MS, and the caller sends only after its exact-slug lookup found nothing.
   */
  async beginCreateSend(key: string, vmId: string, token: string, nowMs?: number): Promise<boolean> {
    return this.storage.transaction(async (storage) => {
      const record = readRecord(await storage.get(`idem:${key}`));
      if (record === undefined) return false;
      const p = record.progress;
      if (p.phase !== "creating" || p.vmId !== vmId || p.cancelRequested === true || p.dispatch === undefined || !sendSettled(p.dispatch, nowMs)) return false;
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
    for (const [key, value] of live) {
      const reservation = checked(isReservation, value);
      if (reservation === undefined || (reservation.retained !== true && reservation.expiresMs <= nowMs)) await storage.delete(key);
      else if (reservation.kind === kind && key !== `reserve:${reservationId}`) inFlight += 1;
    }
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
        if (record.fingerprint !== fingerprint || (record.clientFingerprint !== undefined && clientFingerprint !== undefined && record.clientFingerprint !== clientFingerprint) || (generated !== undefined && JSON.stringify(record.generated) !== JSON.stringify(generated))) return { state: "mismatch" };
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
        if (JSON.stringify(record.progress) === JSON.stringify(progress)) return;
        throw new Error("a completed idempotency record cannot change");
      }
      if (record.leaseUntilMs <= nowMs) throw new Error("idempotency claim expired");
      if (record.progress.phase === "creating") {
        const prior = record.progress;
        if (progress.phase === "creating" && (progress.vmId !== prior.vmId || progress.reservationId !== prior.reservationId || progress.context !== prior.context || progress.createdBy !== prior.createdBy || progress.snapshotId !== prior.snapshotId || JSON.stringify(progress.dispatch) !== JSON.stringify(prior.dispatch) || progress.cancelRequested !== prior.cancelRequested || (prior.intent !== undefined && JSON.stringify(progress.intent) !== JSON.stringify(prior.intent)))) throw new Error("allocation intent changed");
        if (progress.phase !== "creating" && (progress.phase !== "done" || progress.vmId !== prior.vmId)) throw new Error("allocation intent cannot be replaced");
        if (progress.phase === "done") await storage.delete(`reserve:${prior.reservationId}`);
      }
      if (record.progress.phase === "capturing") {
        const prior = record.progress;
        if (progress.phase === "capturing" ? JSON.stringify(progress) !== JSON.stringify(prior)
          : progress.phase !== "creating" || progress.vmId !== prior.vmId || progress.reservationId !== prior.reservationId
            || progress.snapshotId !== prior.snapshotId || progress.createdBy !== prior.createdBy
            || JSON.stringify(progress.intent?.receipt) !== JSON.stringify(prior.receipt)) throw new Error("fork capture intent changed");
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
