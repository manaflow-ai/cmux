import { and, eq, sql, type SQL } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVmHostLeaseOperations, cloudVmHostLeases } from "../../db/schema";
import {
  assertCanReserve,
  MAX_VM_HOST_LEASE_TTL_MS,
  validateVmHostLeaseInput,
  VmHostLeaseError,
  type VmHostLeaseInput,
  type VmHostLeaseProvider,
  type VmHostLeaseProviderResult,
  type VmHostLeaseRecord,
  type VmHostLeaseReservation,
  type VmHostLeaseStore,
} from "./hostLeaseTransport";

/**
 * PostgreSQL-backed host lease store. Reservations are written before provider
 * I/O and every effect receipt is retained by effect key for replay.
 *
 * A transaction advisory lock serializes one (host, lease) tuple without
 * holding a database connection across provider calls. The pending operation
 * row intentionally survives a process crash; a retry reuses its provider
 * idempotency key instead of silently forgetting the effect.
 */
export class DrizzleVmHostLeaseStore implements VmHostLeaseStore {
  async reserve(input: VmHostLeaseInput, provider: VmHostLeaseProvider): Promise<VmHostLeaseReservation> {
    const normalized = validateVmHostLeaseInput(input);
    return cloudDb().transaction(async (tx) => {
      await lockLeaseTuple(tx, normalized.hostId, normalized.leaseId);
      const operation = (await tx.select().from(cloudVmHostLeaseOperations).where(and(
        eq(cloudVmHostLeaseOperations.hostId, normalized.hostId),
        eq(cloudVmHostLeaseOperations.leaseId, normalized.leaseId),
        eq(cloudVmHostLeaseOperations.effectKey, normalized.effectKey),
      )).limit(1))[0];
      if (operation) {
        assertOperationIdentity(operation, normalized, provider);
        if (operation.status === "complete" && operation.receipt) {
          return { kind: "replay", record: recordFromJson(operation.receipt, provider) };
        }
        // A live reservation owns the provider effect. Reclaim only after the
        // maximum provider lease window so a crashed invocation can retry with
        // the same effect key while concurrent callers stay fenced.
        if (operation.updatedAt.getTime() + MAX_VM_HOST_LEASE_TTL_MS > normalized.nowMs) {
          return { kind: "pending", record: null };
        }
        await tx.delete(cloudVmHostLeaseOperations).where(eq(cloudVmHostLeaseOperations.id, operation.id));
      }
      const pendingRows = await tx.select().from(cloudVmHostLeaseOperations).where(and(
        eq(cloudVmHostLeaseOperations.hostId, normalized.hostId),
        eq(cloudVmHostLeaseOperations.leaseId, normalized.leaseId),
        eq(cloudVmHostLeaseOperations.status, "pending"),
      ));
      for (const pending of pendingRows) {
        if (pending.updatedAt.getTime() + MAX_VM_HOST_LEASE_TTL_MS > normalized.nowMs) return { kind: "pending", record: null };
        await tx.delete(cloudVmHostLeaseOperations).where(eq(cloudVmHostLeaseOperations.id, pending.id));
      }
      const currentRow = (await tx.select().from(cloudVmHostLeases).where(and(
        eq(cloudVmHostLeases.hostId, normalized.hostId),
        eq(cloudVmHostLeases.leaseId, normalized.leaseId),
      )).limit(1))[0];
      const current = currentRow ? recordFromRow(currentRow) : undefined;
      assertCanReserve(current, normalized, provider);
      const [inserted] = await tx.insert(cloudVmHostLeaseOperations).values({
        provider,
        hostId: normalized.hostId,
        leaseId: normalized.leaseId,
        ownerId: normalized.ownerId,
        effectKey: normalized.effectKey,
        operation: normalized.operation,
        generation: normalized.generation,
        status: "pending",
        receipt: null,
        updatedAt: new Date(normalized.nowMs),
      }).returning({ id: cloudVmHostLeaseOperations.id });
      if (!inserted) throw new VmHostLeaseError("store_error", "lease reservation was not persisted");
      return { kind: "new", reservationToken: inserted.id, record: null };
    });
  }

  async complete(input: VmHostLeaseInput, provider: VmHostLeaseProvider, result: VmHostLeaseProviderResult, reservationToken: string): Promise<VmHostLeaseRecord> {
    const normalized = validateVmHostLeaseInput(input);
    const record = recordFromResult(normalized, provider, result);
    return cloudDb().transaction(async (tx) => {
      await lockLeaseTuple(tx, normalized.hostId, normalized.leaseId);
      const operation = (await tx.select().from(cloudVmHostLeaseOperations).where(eq(cloudVmHostLeaseOperations.id, reservationToken)).limit(1))[0];
      if (!operation) throw new VmHostLeaseError("store_error", "lease completion has no reservation");
      if (operation.hostId !== normalized.hostId || operation.leaseId !== normalized.leaseId || operation.effectKey !== normalized.effectKey) {
        throw new VmHostLeaseError("stale_generation", "lease completion token belongs to another operation");
      }
      assertOperationIdentity(operation, normalized, provider);
      if (operation.status === "complete" && operation.receipt) return recordFromJson(operation.receipt, provider);

      const currentRow = (await tx.select().from(cloudVmHostLeases).where(and(
        eq(cloudVmHostLeases.hostId, normalized.hostId),
        eq(cloudVmHostLeases.leaseId, normalized.leaseId),
      )).limit(1))[0];
      if (currentRow && currentRow.provider !== provider) {
        throw new VmHostLeaseError("provider_mismatch", "lease completion belongs to another provider");
      }
      if (currentRow && currentRow.generation > normalized.generation) {
        throw new VmHostLeaseError("stale_generation", "lease completion is fenced by a newer generation");
      }
      if (currentRow && currentRow.ownerId !== normalized.ownerId) {
        throw new VmHostLeaseError("owner_mismatch", "lease completion belongs to another coordinator");
      }
      if (currentRow && currentRow.state === "released"
        && (normalized.operation === "renew" || normalized.generation <= currentRow.generation)) {
        throw new VmHostLeaseError("lease_expired", "a released host lease cannot be renewed");
      }
      if (currentRow) {
        await tx.update(cloudVmHostLeases).set({
          provider: record.provider,
          ownerId: record.ownerId,
          generation: record.generation,
          state: record.state,
          providerLeaseId: record.providerLeaseId,
          expiresAt: new Date(record.expiresAtMs),
          metadata: { ...record.metadata },
          updatedAt: new Date(normalized.nowMs),
        }).where(eq(cloudVmHostLeases.id, currentRow.id));
      } else {
        await tx.insert(cloudVmHostLeases).values({
          provider: record.provider,
          hostId: record.hostId,
          leaseId: record.leaseId,
          ownerId: record.ownerId,
          generation: record.generation,
          state: record.state,
          providerLeaseId: record.providerLeaseId,
          expiresAt: new Date(record.expiresAtMs),
          metadata: { ...record.metadata },
          updatedAt: new Date(normalized.nowMs),
        });
      }
      await tx.update(cloudVmHostLeaseOperations).set({
        status: "complete",
        receipt: { ...record, metadata: { ...record.metadata } },
        updatedAt: new Date(normalized.nowMs),
      }).where(eq(cloudVmHostLeaseOperations.id, operation.id));
      return record;
    });
  }

  async abort(input: VmHostLeaseInput, provider: VmHostLeaseProvider, reservationToken: string): Promise<void> {
    const normalized = validateVmHostLeaseInput(input);
    await cloudDb().transaction(async (tx) => {
      await lockLeaseTuple(tx, normalized.hostId, normalized.leaseId);
      const operation = (await tx.select().from(cloudVmHostLeaseOperations).where(eq(cloudVmHostLeaseOperations.id, reservationToken)).limit(1))[0];
      if (!operation || operation.status !== "pending") return;
      if (operation.hostId !== normalized.hostId || operation.leaseId !== normalized.leaseId || operation.effectKey !== normalized.effectKey) {
        throw new VmHostLeaseError("stale_generation", "lease abort token belongs to another operation");
      }
      assertOperationIdentity(operation, normalized, provider);
      await tx.delete(cloudVmHostLeaseOperations).where(eq(cloudVmHostLeaseOperations.id, reservationToken));
    });
  }
}

async function lockLeaseTuple(tx: { execute: (query: SQL) => Promise<unknown> }, hostId: string, leaseId: string): Promise<void> {
  // hashtextextended is stable within PostgreSQL and gives us a transaction
  // scoped lock without embedding a NUL in text (PostgreSQL rejects NUL in
  // text values). Two independent hashes avoid delimiter collisions.
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${hostId}, 0) # hashtextextended(${leaseId}, 1))`);
}

function assertOperationIdentity(
  operation: typeof cloudVmHostLeaseOperations.$inferSelect,
  input: Required<VmHostLeaseInput>,
  provider: VmHostLeaseProvider,
): void {
  if (operation.provider !== provider) throw new VmHostLeaseError("provider_mismatch", "lease operation belongs to another provider");
  if (operation.ownerId !== input.ownerId) throw new VmHostLeaseError("owner_mismatch", "lease operation belongs to another coordinator");
  if (operation.generation !== input.generation || operation.operation !== input.operation) {
    throw new VmHostLeaseError("stale_generation", "lease operation generation or operation does not match");
  }
}

function recordFromRow(row: typeof cloudVmHostLeases.$inferSelect): VmHostLeaseRecord {
  if (!/^[a-z][a-z0-9-]{1,63}$/.test(row.provider)) throw new VmHostLeaseError("store_error", "stored lease has an unknown provider");
  if (row.state !== "active" && row.state !== "released") throw new VmHostLeaseError("store_error", "stored lease has an unknown state");
  return {
    provider: row.provider,
    operation: row.state === "released" ? "release" : "acquire",
    leaseId: row.leaseId,
    hostId: row.hostId,
    ownerId: row.ownerId,
    generation: row.generation,
    state: row.state,
    expiresAtMs: row.expiresAt.getTime(),
    effectKey: "stored",
    providerLeaseId: row.providerLeaseId,
    metadata: row.metadata,
  };
}

function recordFromJson(value: Record<string, unknown>, provider: VmHostLeaseProvider): VmHostLeaseRecord {
  const operation = value.operation;
  const state = value.state;
  if ((operation !== "acquire" && operation !== "renew" && operation !== "release") || (state !== "active" && state !== "released")) {
    throw new VmHostLeaseError("store_error", "stored lease receipt has an invalid lifecycle");
  }
  if (value.provider !== provider || typeof value.leaseId !== "string" || typeof value.hostId !== "string" || typeof value.ownerId !== "string" || typeof value.effectKey !== "string" || typeof value.generation !== "number" || typeof value.expiresAtMs !== "number") {
    throw new VmHostLeaseError("store_error", "stored lease receipt is malformed");
  }
  return {
    provider,
    operation,
    state,
    leaseId: value.leaseId,
    hostId: value.hostId,
    ownerId: value.ownerId,
    generation: value.generation,
    expiresAtMs: value.expiresAtMs,
    effectKey: value.effectKey,
    providerLeaseId: typeof value.providerLeaseId === "string" ? value.providerLeaseId : null,
    metadata: value.metadata && typeof value.metadata === "object" && !Array.isArray(value.metadata) ? value.metadata as Record<string, unknown> : {},
  };
}

function recordFromResult(
  input: Required<VmHostLeaseInput>,
  provider: VmHostLeaseProvider,
  result: VmHostLeaseProviderResult,
): VmHostLeaseRecord {
  if (result.generation !== undefined && result.generation !== null && result.generation !== input.generation) {
    throw new VmHostLeaseError("receipt_mismatch", "provider lease receipt returned a different generation");
  }
  const expiresAtMs = input.operation === "release" ? input.nowMs : result.expiresAtMs ?? input.nowMs + input.ttlMs;
  if (!Number.isSafeInteger(expiresAtMs) || (input.operation !== "release" && expiresAtMs <= input.nowMs)) {
    throw new VmHostLeaseError("receipt_mismatch", "provider lease receipt returned an invalid expiry");
  }
  return {
    operation: input.operation,
    provider,
    leaseId: input.leaseId,
    hostId: input.hostId,
    ownerId: input.ownerId,
    generation: input.generation,
    state: input.operation === "release" ? "released" : "active",
    expiresAtMs,
    effectKey: input.effectKey,
    providerLeaseId: typeof result.providerLeaseId === "string" ? result.providerLeaseId : null,
    metadata: result.metadata ?? {},
  };
}
