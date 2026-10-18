/**
 * One Durable Object per tenant (named by tenant id). A Durable Object runs one
 * call at a time, so the ledger's read-modify-write steps cannot interleave:
 * two concurrent creates cannot both take the last quota slot, and two
 * requests with the same idempotency key cannot both start.
 */
import { DurableObject } from "cloudflare:workers";
import {
  TenantLedger,
  type LedgerStorage,
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

  begin(key: string, fingerprint: string, nowMs: number): Promise<IdempotencyBegin> {
    return this.ledger.begin(key, fingerprint, nowMs);
  }

  advance(key: string, progress: IdempotencyProgress, nowMs: number): Promise<void> {
    return this.ledger.advance(key, progress, nowMs);
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
