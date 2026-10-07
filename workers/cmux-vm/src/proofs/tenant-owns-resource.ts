/**
 * Trusted module: the only place a TenantOwnsResource proof is minted.
 *
 * The upstream id the ownership lookup found is the proof's evidence. It is
 * kept in a module-private WeakMap keyed by the exact proof object, never on
 * the proof itself, so a copied or hand-built proof (`{ ...proof }`) carries
 * no upstream id and cannot be pointed at another resource. Only code holding
 * a minted proof can read the id, through `upstreamIdOf`.
 */
import { defineProof, name, type Named, type NameOf, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { OwnershipStore, type OwnedResource, type PagePosition } from "../db/stores.ts";
import type { StoreError } from "../db/sql.ts";
import type { Principal } from "../domain/principal.ts";
import { parseVmId, type DeviceId, type MeshId, type ResourceId, type ResourceKind, type SnapshotId, type TunnelId, type UpstreamId, type VmId } from "../lib/ids.ts";

const TenantOwnsResource = defineProof("TenantOwnsResource");

/** The tenant of caller `C` owns the public resource named `R`, and `C` may reach it. */
export interface TenantOwnsResource<C, R> extends Proof<"TenantOwnsResource", [C, R]> {
  /** The ownership row's display name and labels (public data, not evidence). */
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
}

const evidence = new WeakMap<object, UpstreamId>();

/** The upstream id this proof was minted for. A proof not minted here has none. */
export const upstreamIdOf = <C, R>(proof: TenantOwnsResource<C, R>): UpstreamId => {
  const upstreamId = evidence.get(proof);
  if (upstreamId === undefined) throw new Error("TenantOwnsResource proof was not minted by src/proofs");
  return upstreamId;
};

const owns = <C, R>(
  caller: Named<C, Principal>,
  resource: Named<R, ResourceId>,
  kind: ResourceKind,
): Effect.Effect<TenantOwnsResource<C, R> | null, StoreError, OwnershipStore> =>
  Effect.gen(function* () {
    const principal = caller.value;
    if (principal.resourceAllowlist !== null && !principal.resourceAllowlist.has(resource.value)) return null;
    const store = yield* OwnershipStore;
    const found = yield* store.find(principal.tenantId, kind, resource.value);
    if (Option.isNone(found) || found.value.tenantId !== principal.tenantId) return null;
    return mint(caller, resource, found.value);
  });

/** A fresh object per mint: the WeakMap entry belongs to this proof only. */
const mint = <C, R>(caller: Named<C, Principal>, resource: Named<R, unknown>, row: OwnedResource): TenantOwnsResource<C, R> => {
  const proof: TenantOwnsResource<C, R> = Object.freeze({
    ...TenantOwnsResource.prove(caller, resource),
    displayName: row.displayName,
    labels: row.labels,
  });
  evidence.set(proof, row.upstreamId);
  return proof;
};

export const tenantOwnsVm = <C, R>(caller: Named<C, Principal>, vm: Named<R, VmId>) => owns(caller, vm, "vm");

export const tenantOwnsSnapshot = <C, R>(caller: Named<C, Principal>, snapshot: Named<R, SnapshotId>) =>
  owns(caller, snapshot, "snapshot");

/** Mesh experiment (cx-0op): a mesh's upstream id is its private network. */
export const tenantOwnsMesh = <C, R>(caller: Named<C, Principal>, mesh: Named<R, MeshId>) => owns(caller, mesh, "mesh");

/** A device's upstream id is its tunnel's: deleting the device deletes exactly that tunnel. */
export const tenantOwnsDevice = <C, R>(caller: Named<C, Principal>, device: Named<R, DeviceId>) => owns(caller, device, "device");

export const tenantOwnsTunnel = <C, R>(caller: Named<C, Principal>, tunnel: Named<R, TunnelId>) => owns(caller, tunnel, "tunnel");

/** What a list handler may read from an ownership row; the upstream id stays with the proof. */
export type OwnedRowView = Pick<OwnedResource, "cmuxId" | "displayName" | "createdAt" | "labels">;

/** One row of a list page, with its ownership proof, scoped to the callback. */
export type OwnedVmVisitor<C, A, E, R> = <V>(vm: Named<V, VmId>, owns: TenantOwnsResource<C, V>, row: OwnedRowView) => Effect.Effect<A, E, R>;

export interface OwnedVmPage<A> {
  /** Rows read from the ownership table (before the visitor dropped any). */
  readonly fetched: number;
  /** Position of the last row read, for the next page; null when none. */
  readonly last: PagePosition | null;
  readonly results: ReadonlyArray<A>;
}

/**
 * Lists the caller's tenant's live VMs newest first (honoring a key's resource
 * allowlist and a label filter) and visits each with a proof that the tenant
 * owns it. The rows come from a query keyed by the caller's tenant, so each
 * proof stands on the same fact a single `tenantOwnsVm` check establishes.
 */
export const visitOwnedVms = <C, A, E, R>(
  caller: Named<C, Principal>,
  page: { readonly limit: number; readonly after: PagePosition | null; readonly labels: Readonly<Record<string, string>> | null },
  visit: OwnedVmVisitor<C, A, E, R>,
  concurrency = 8,
): Effect.Effect<OwnedVmPage<A>, E | StoreError, R | OwnershipStore> =>
  Effect.gen(function* () {
    const principal = caller.value;
    const store = yield* OwnershipStore;
    const rows = yield* store.listPage(principal.tenantId, "vm", { ...page, only: principal.resourceAllowlist });
    const results = yield* Effect.forEach(
      rows.filter((row) => row.tenantId === principal.tenantId && row.kind === "vm"),
      (row) => {
        const parsed = parseVmId(row.cmuxId);
        if (Option.isNone(parsed)) return Effect.succeed(Option.none<A>());
        return name(parsed.value, (vm) => {
          const owns: TenantOwnsResource<C, NameOf<typeof vm>> = mint(caller, vm, row);
          const view: OwnedRowView = { cmuxId: row.cmuxId, displayName: row.displayName, createdAt: row.createdAt, labels: row.labels };
          return Effect.map(visit(vm, owns, view), Option.some);
        });
      },
      { concurrency },
    );
    const lastRow = rows.at(-1);
    return {
      fetched: rows.length,
      last: lastRow === undefined ? null : { createdAt: lastRow.createdAt, cmuxId: lastRow.cmuxId },
      results: results.flatMap((result) => (Option.isSome(result) ? [result.value] : [])),
    };
  });
