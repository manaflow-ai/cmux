import type { cloudRuntimes } from "../../db/schema";

export type RuntimeRow = typeof cloudRuntimes.$inferSelect;
export type RuntimeKind = RuntimeRow["runtimeKind"];
export type RuntimeLifecycleState = RuntimeRow["lifecycleState"];

/** The placement tuple carried across asynchronous provider work. */
export type RuntimePlacement = {
  readonly runtimeId: string;
  readonly machineId: string | null;
  readonly generation: number;
};

/** A lease fence is safe to compare without returning the token to clients. */
export type RuntimeLeaseFence = {
  readonly generation: number;
  readonly expiresAt: Date | null;
};

export type CreateRuntimeInput = {
  readonly ownerTeamId: string;
  readonly kind?: RuntimeKind;
  readonly lifecycleState?: RuntimeLifecycleState;
  readonly machineId?: string | null;
  readonly journalSessionId?: string | null;
  readonly idempotencyKey?: string | null;
};

export type UpdateRuntimeInput = {
  readonly ownerTeamId: string;
  readonly runtimeId: string;
  readonly lifecycleState?: RuntimeLifecycleState;
  readonly machineId?: string | null;
  readonly journalSessionId?: string | null;
  /** Required when changing placement; stale generations are rejected. */
  readonly expectedPlacementGeneration?: number;
  /** Required when changing a leased runtime; stale lease generations are rejected. */
  readonly expectedLeaseGeneration?: number;
  /** Internal lease material; never returned from a public view. */
  readonly leaseToken?: string | null;
  readonly leaseExpiresAt?: Date | null;
};

/** Deliberately excludes ownership, machine/provider handles, idempotency and lease material. */
export type RuntimeView = {
  readonly id: string;
  readonly kind: RuntimeKind;
  readonly lifecycleState: RuntimeLifecycleState;
  readonly placementGeneration: number;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly releasedAt: string | null;
};

function iso(value: Date | string | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

export function toRuntimeView(runtime: RuntimeRow): RuntimeView {
  return {
    id: runtime.id,
    kind: runtime.runtimeKind,
    lifecycleState: runtime.lifecycleState,
    placementGeneration: runtime.placementGeneration,
    createdAt: iso(runtime.createdAt) ?? new Date(0).toISOString(),
    updatedAt: iso(runtime.updatedAt) ?? new Date(0).toISOString(),
    releasedAt: iso(runtime.releasedAt),
  };
}

