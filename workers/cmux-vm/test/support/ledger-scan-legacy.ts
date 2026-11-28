/**
 * The ledger's per-call scans as they were before the batched rewrite (2026-11-27), kept verbatim as the oracle the
 * model-based test (test/node/ledger-scan-model.test.ts) checks the new code against and as the "before" leg of the
 * bench (test/workers/ledger-scan-bench.test.ts). Not used by the Worker.
 */
import { Schema } from "effect";
import { ADMIT_TTL_MS } from "../../src/limits/agent-slots.ts";
import { readIdempotencyRecord as readRecord, RESERVATION_TTL_MS, type RetainedCreationSlot } from "../../src/limits/ledger.ts";
import { Reservation, type LedgerStorage } from "../../src/limits/storage.ts";

const isReservation = Schema.is(Reservation);
const isRetainedSlot = Schema.is(Schema.Struct({ ...Reservation.fields, vmCreation: Schema.optional(Schema.Unknown) }));
const isSlotLink = Schema.is(Schema.Struct({ key: Schema.String, vmId: Schema.String }));
const isAgentSlot = Schema.is(Schema.Struct({ expiresMs: Schema.Number, vmId: Schema.optional(Schema.String), creationKey: Schema.optional(Schema.String) }));

export const legacyReserve = (store: LedgerStorage, kind: string, limit: number, liveCount: number, nowMs: number, reservationId: string) =>
  store.transaction(async (storage) => {
    const live = await storage.list({ prefix: "reserve:" });
    let inFlight = 0;
    for (const [key, value] of live) {
      const reservation = isReservation(value) ? value : undefined;
      if (reservation === undefined || (reservation.retained !== true && reservation.expiresMs <= nowMs)) await storage.delete(key);
      else if (reservation.kind === kind && key !== `reserve:${reservationId}`) inFlight += 1;
    }
    if (liveCount + inFlight >= limit) return { ok: false as const };
    await storage.put(`reserve:${reservationId}`, { kind, expiresMs: nowMs + RESERVATION_TTL_MS });
    return { ok: true as const, reservationId };
  });

export const legacyRetainedCreations = async (storage: LedgerStorage, createdBy: string, limit: number): Promise<ReadonlyArray<RetainedCreationSlot>> => {
  const slots = new Set<string>();
  const links = new Map<string, string>();
  for (const [key, value] of await storage.list({ prefix: "reserve:" })) {
    if (!isRetainedSlot(value) || value.kind !== "vm" || value.retained !== true) continue;
    slots.add(key.slice("reserve:".length));
    if (isSlotLink(value.vmCreation)) links.set(key.slice("reserve:".length), value.vmCreation.key);
  }
  if (slots.size === 0) return [];
  const keys = new Set(links.values());
  if (links.size < slots.size) {
    for (const [key, value] of await storage.list({ prefix: "idem:", limit: 256 })) {
      const p = readRecord(value)?.progress;
      if (p?.phase === "creating" && slots.has(p.reservationId)) keys.add(key.slice("idem:".length));
    }
  }
  const found: RetainedCreationSlot[] = [];
  for (const key of keys) {
    const p = readRecord(await storage.get(`idem:${key}`))?.progress;
    if (p?.phase !== "creating" || !slots.has(p.reservationId) || p.createdBy !== createdBy || p.intent === undefined || p.dispatch === undefined) continue;
    const startedMs = p.dispatch.at ?? Date.parse(p.intent.createdAt);
    if (!Number.isFinite(startedMs)) continue;
    found.push({ key, vmId: p.vmId, startedMs, cancelRequested: p.cancelRequested === true });
  }
  return found.sort((a, b) => a.startedMs - b.startedMs).slice(0, limit);
};

export const legacyAdmitAgentSlot = (storage: LedgerStorage, agent: string, limit: number, ownedVmIds: ReadonlyArray<string>, nowMs: number, slotId: string): Promise<boolean> =>
  storage.transaction(async (tx) => {
    const held = new Set(ownedVmIds);
    for (const [key, value] of await tx.list({ prefix: `agentslot:${agent}:` })) {
      if (!isAgentSlot(value) || value.expiresMs <= nowMs) await tx.delete(key);
      else held.add(value.vmId ?? key);
    }
    if (held.size >= limit) return false;
    await tx.put(`agentslot:${agent}:${slotId}`, { expiresMs: nowMs + ADMIT_TTL_MS });
    return true;
  });

export const legacyForgetAgentVm = (storage: LedgerStorage, vmId: string, creationKey: string | null): Promise<void> =>
  storage.transaction(async (tx) => {
    for (const [key, value] of await tx.list({ prefix: "agentslot:" })) {
      if (isAgentSlot(value) && (value.vmId === vmId || (creationKey !== null && value.creationKey === creationKey))) await tx.delete(key);
    }
  });
