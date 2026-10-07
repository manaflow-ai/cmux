/**
 * Trusted module: the only place a TenantOwnsResource proof is minted.
 *
 * The proof carries the upstream id it found as evidence. That is the only way
 * code outside the stores can obtain an upstream id, so an upstream call cannot
 * be pointed at a resource the ownership table did not resolve for this caller.
 */
import { defineProof, name, type Named, type NameOf, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { OwnershipStore, type OwnedResource, type PagePosition } from "../db/stores.ts";
import type { StoreError } from "../db/sql.ts";
import type { Principal } from "../domain/principal.ts";
import { parseVmId, type ResourceKind, type SnapshotId, type UpstreamId, type VmId } from "../lib/ids.ts";

const TenantOwnsResource = defineProof("TenantOwnsResource");

/** The tenant of caller `C` owns the public resource named `R`, and `C` may reach it. */
export interface TenantOwnsResource<C, R> extends Proof<"TenantOwnsResource", [C, R]> {
  readonly upstreamId: UpstreamId;
  /** The resource's display name and labels from the ownership row. */
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
}

const owns = <C, R>(
  caller: Named<C, Principal>,
  resource: Named<R, VmId | SnapshotId>,
  kind: ResourceKind,
): Effect.Effect<TenantOwnsResource<C, R> | null, StoreError, OwnershipStore> =>
  Effect.gen(function* () {
    const principal = caller.value;
    if (principal.resourceAllowlist !== null && !principal.resourceAllowlist.has(resource.value)) return null;
    const store = yield* OwnershipStore;
    const found = yield* store.find(principal.tenantId, kind, resource.value);
    if (Option.isNone(found) || found.value.tenantId !== principal.tenantId) return null;
    const proof: TenantOwnsResource<C, R> = Object.freeze({
      ...TenantOwnsResource.prove(caller, resource),
      upstreamId: found.value.upstreamId,
      displayName: found.value.displayName,
      labels: found.value.labels,
    });
    return proof;
  });

export const tenantOwnsVm = <C, R>(caller: Named<C, Principal>, vm: Named<R, VmId>) => owns(caller, vm, "vm");

export const tenantOwnsSnapshot = <C, R>(caller: Named<C, Principal>, snapshot: Named<R, SnapshotId>) =>
  owns(caller, snapshot, "snapshot");

/** What a list handler may read from an ownership row; the upstream id stays inside the proof. */
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
 * allowlist) and visits each with a proof that the tenant owns it. The rows
 * come from a query keyed by the caller's tenant, so each proof stands on the
 * same fact a single `tenantOwnsVm` check establishes.
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
      rows.filter((row) => row.tenantId === principal.tenantId),
      (row) => {
        const parsed = parseVmId(row.cmuxId);
        if (Option.isNone(parsed)) return Effect.succeed(Option.none<A>());
        return name(parsed.value, (vm) => {
          const owns: TenantOwnsResource<C, NameOf<typeof vm>> = Object.freeze({
            ...TenantOwnsResource.prove(caller, vm),
            upstreamId: row.upstreamId,
            displayName: row.displayName,
            labels: row.labels,
          });
          return Effect.map(visit(vm, owns, { cmuxId: row.cmuxId, displayName: row.displayName, createdAt: row.createdAt, labels: row.labels }), Option.some);
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
