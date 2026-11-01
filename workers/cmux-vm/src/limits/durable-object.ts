/**
 * One Durable Object per tenant (named by tenant id). A Durable Object runs one
 * call at a time, so the ledger's read-modify-write steps cannot interleave:
 * two concurrent creates cannot both take the last quota slot, and two
 * requests with the same idempotency key cannot both start.
 */
import type { SnapshotCaptureCommand, SnapshotCaptureResult } from "./snapshot-capture.ts";
import type { MeshCreationCommand, MeshCreationResult } from "./mesh-creation.ts";
import type { GeneratedCreation, GeneratedCreationPage } from "../domain/generated-creation.ts";
import { DurableObject } from "cloudflare:workers";
import {
  TenantLedger,
  type LedgerStorage,
  type CancelCreationDecision,
  type IdempotencyRecord,
  type IdempotencyBegin,
  type IdempotencyProgress,
  type RateClass,
  type RateDecision,
  type RateRule,
  type ReserveDecision,
} from "./ledger.ts";

const storageOf = (store: DurableObjectStorage | DurableObjectTransaction): LedgerStorage => ({
  get: (key) => store.get(key), put: (key, value) => store.put(key, value),
  delete: (key) => store.delete(key), list: (options) => store.list(options),
  transaction: (run) => "transaction" in store ? store.transaction((tx) => run(storageOf(tx))) : run(storageOf(store)),
});

export class TenantLimitsObject extends DurableObject {
  private readonly ledger = new TenantLedger(storageOf(this.ctx.storage));

  meshCreation(command: MeshCreationCommand, nowMs: number): Promise<MeshCreationResult> { return this.ledger.meshCreation(command, nowMs); }

  snapshotCapture(command: SnapshotCaptureCommand, nowMs: number): Promise<SnapshotCaptureResult> { return this.ledger.snapshotCapture(command, nowMs); }

  beginCreateSend(key: string, vmId: string, token: string, nowMs: number): Promise<boolean> { return this.ledger.beginCreateSend(key, vmId, token, nowMs); }
  settleAbsentCancellation(key: string, vmId: string, nowMs: number): Promise<boolean> { return this.ledger.settleAbsentCancellation(key, vmId, nowMs); }
  readmitCreation(key: string, vmId: string, limit: number, liveCount: number, nowMs: number): Promise<"readmitted" | "over_quota" | "none"> { return this.ledger.readmitCreation(key, vmId, limit, liveCount, nowMs); }
  rejectCreateSend(key: string, vmId: string, token: string): Promise<boolean> { return this.ledger.rejectCreateSend(key, vmId, token); }
  creationActive(key: string, vmId: string): Promise<boolean> { return this.ledger.creationActive(key, vmId); }
  cancelCreation(key: string, vmId: string): Promise<CancelCreationDecision> { return this.ledger.cancelCreation(key, vmId); }
  settleCancellation(key: string, vmId: string): Promise<boolean> { return this.ledger.settleCancellation(key, vmId); }

  inspect(key: string): Promise<IdempotencyRecord | null> { return this.ledger.inspect(key); }
  quarantineForkClaim(key: string, nowMs: number): Promise<boolean> { return this.ledger.quarantineForkClaim(key, nowMs); }

  async settleCreation(key: string, vmId: string, nowMs: number): Promise<boolean> {
    try { await this.ledger.settleCreation(key, vmId, nowMs); return true; }
    catch { return false; }
  }

  creationReservation(key: string, vmId: string): Promise<string | null> { return this.ledger.creationReservation(key, vmId); }

  rate(rateClass: RateClass, rule: RateRule, nowMs: number): Promise<RateDecision> {
    return this.ledger.rate(rateClass, rule, nowMs);
  }

  reserve(kind: string, limit: number, liveCount: number, nowMs: number, reservationId: string): Promise<ReserveDecision> {
    return this.ledger.reserve(kind, limit, liveCount, nowMs, reservationId);
  }

  release(reservationId: string): Promise<void> {
    return this.ledger.release(reservationId);
  }

  listGenerated(scope: string, cursor: string | undefined, limit: number, pending?: boolean): Promise<GeneratedCreationPage> { return this.ledger.listGenerated(scope, cursor, limit, pending); }

  begin(key: string, fingerprint: string, nowMs: number, clientFingerprint?: string, generated?: GeneratedCreation): Promise<IdempotencyBegin> {
    return this.ledger.begin(key, fingerprint, nowMs, clientFingerprint, generated);
  }

  async advance(key: string, progress: IdempotencyProgress, nowMs: number): Promise<boolean> {
    // Expected stale/conflicting claims return a receipt rather than a rejected RPC promise.
    try { await this.ledger.advance(key, progress, nowMs); return true; }
    catch { return false; }
  }

  abandon(key: string, nowMs: number): Promise<void> {
    return this.ledger.abandon(key, nowMs);
  }

  lock(key: string, holder: string, leaseMs: number, nowMs: number): Promise<boolean> {
    return this.ledger.lock(key, holder, leaseMs, nowMs);
  }

  unlock(key: string, holder: string): Promise<void> {
    return this.ledger.unlock(key, holder);
  }
}
