/**
 * Trusted module: mints TenantMayCreate proofs for the mesh experiment's
 * kinds (cx-0op). Same contract as tenant-may-create.ts: billing first, then
 * the budget, with a reservation in the tenant's ledger so two concurrent
 * creates cannot both take the last slot. Release the reservation once the
 * new rows are recorded or the create failed.
 *
 * Budgets (DESIGN.md 7.1): `mesh.perTenant` counts the tenant's live meshes;
 * `device.perMesh` counts the live devices of one mesh, so its reservation
 * key names the mesh.
 */
import { defineProof, type Named } from "@gdp-ts/core";
import { Effect } from "effect";
import { MeshStore } from "../db/mesh.ts";
import type { StoreError } from "../db/sql.ts";
import { OwnershipStore } from "../db/stores.ts";
import type { Principal } from "../domain/principal.ts";
import type { MeshId } from "../lib/ids.ts";
import { TenantLimits, type LimitsUnavailable } from "../limits/service.ts";
import { MeshConfig } from "../mesh/config.ts";
import { Entitlements, type EntitlementUnavailable, type TenantMayCreate } from "./tenant-may-create.ts";

export type MeshCreateDecision<C, K extends "mesh" | "device"> =
  | { readonly _tag: "granted"; readonly proof: TenantMayCreate<C, K> }
  | { readonly _tag: "not_entitled" }
  | { readonly _tag: "over_budget"; readonly limit: number };

type Needs = Entitlements | OwnershipStore | MeshStore | TenantLimits | MeshConfig;

const decide = <C, const K extends "mesh" | "device">(
  caller: Named<C, Principal>,
  kind: K,
  reservationKind: string,
  limit: number,
  live: Effect.Effect<number, StoreError, Needs>,
): Effect.Effect<MeshCreateDecision<C, K>, EntitlementUnavailable | StoreError | LimitsUnavailable, Needs> =>
  Effect.gen(function* () {
    const tenantId = caller.value.tenantId;
    if (!(yield* (yield* Entitlements).mayCreate(tenantId, kind))) return { _tag: "not_entitled" };
    const count = yield* live;
    const reserved = yield* (yield* TenantLimits).reserve(tenantId, reservationKind, limit, count);
    if (!reserved.ok) return { _tag: "over_budget", limit };
    const TenantMayCreate = defineProof(`TenantMayCreate:${kind}`);
    const proof: TenantMayCreate<C, K> = Object.freeze({ ...TenantMayCreate.prove(caller), reservationId: reserved.reservationId });
    return { _tag: "granted", proof };
  });

/** One more mesh for the caller's tenant (`mesh.perTenant`). */
export const tenantMayCreateMesh = <C>(caller: Named<C, Principal>) =>
  Effect.flatMap(MeshConfig, (config) =>
    decide(
      caller,
      "mesh",
      "mesh",
      config.budgets.meshesPerTenant,
      Effect.flatMap(OwnershipStore, (store) => store.countLive(caller.value.tenantId, "mesh")),
    ),
  );

/** One more device in `mesh` (`device.perMesh`). The caller must already hold the mesh's ownership proof. */
export const tenantMayCreateDevice = <C, M>(caller: Named<C, Principal>, mesh: Named<M, MeshId>) =>
  Effect.flatMap(MeshConfig, (config) =>
    decide(
      caller,
      "device",
      `device:${mesh.value}`,
      config.budgets.devicesPerMesh,
      Effect.flatMap(MeshStore, (store) => Effect.map(store.listDevices(caller.value.tenantId, mesh.value), (rows) => rows.length)),
    ),
  );
