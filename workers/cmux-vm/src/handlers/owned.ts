/**
 * Resolves a public resource id for the caller, in the order every endpoint
 * uses: prove the scope (403 never depends on which resource was asked for),
 * then prove the caller's tenant owns the resource (anything else, including a
 * malformed id or another tenant's resource, is the same 404), then run the
 * handler with both proofs.
 */
import { name, type Named } from "@gdp-ts/core";
import { Effect, Option, Schema } from "effect";
import type { StoreError } from "../db/sql.ts";
import type { OwnershipStore } from "../db/stores.ts";
import { CurrentPrincipal, type Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import { missingScope, NotFound, unavailable, vmNotFound } from "../errors.ts";
import { SnapshotId, VmId } from "../lib/ids.ts";
import { keyHasScope, type KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantOwnsSnapshot, tenantOwnsVm, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";

export const snapshotNotFound = () => new NotFound({ message: "Snapshot not found" });

interface ResourceKindSpec<Id> {
  readonly parse: (raw: string) => Option.Option<Id>;
  readonly prove: <C, R>(
    caller: Named<C, Principal>,
    resource: Named<R, Id>,
  ) => Effect.Effect<TenantOwnsResource<C, R> | null, StoreError, OwnershipStore>;
  readonly notFound: () => NotFound;
}

export const OwnedVm: ResourceKindSpec<VmId> = {
  parse: Schema.decodeUnknownOption(VmId),
  prove: tenantOwnsVm,
  notFound: vmNotFound,
};

export const OwnedSnapshot: ResourceKindSpec<SnapshotId> = {
  parse: Schema.decodeUnknownOption(SnapshotId),
  prove: tenantOwnsSnapshot,
  notFound: snapshotNotFound,
};

export const withOwned = <Id, const S extends Scope, A, E, R>(
  kind: ResourceKindSpec<Id>,
  rawId: string,
  scope: S,
  k: <C, V>(
    caller: Named<C, Principal>,
    resource: Named<V, Id>,
    proofs: { readonly owns: TenantOwnsResource<C, V>; readonly scope: KeyHasScope<C, S> },
  ) => Effect.Effect<A, E, R>,
) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    // Scope first, before the id is even parsed, so a 403 says nothing about the id.
    const scoped = yield* name(principal, (caller) => Effect.succeed(keyHasScope(caller, scope) !== null));
    if (!scoped) return yield* Effect.fail(missingScope(scope));
    const parsed = kind.parse(rawId);
    if (Option.isNone(parsed)) return yield* Effect.fail(kind.notFound());
    return yield* name(principal, parsed.value, (caller, resource) =>
      Effect.gen(function* () {
        const granted = keyHasScope(caller, scope);
        if (granted === null) return yield* Effect.fail(missingScope(scope));
        const owns = yield* kind.prove(caller, resource).pipe(Effect.mapError(() => unavailable()));
        if (owns === null) return yield* Effect.fail(kind.notFound());
        return yield* k(caller, resource, { owns, scope: granted });
      }),
    );
  });

/** Proves `scope` for the caller with no resource involved, then runs `k` with the proof. */
export const withScope = <const S extends Scope, A, E, R>(
  scope: S,
  k: <C>(caller: Named<C, Principal>, proof: KeyHasScope<C, S>) => Effect.Effect<A, E, R>,
) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    return yield* name(principal, (caller) =>
      Effect.gen(function* () {
        const granted = keyHasScope(caller, scope);
        if (granted === null) return yield* Effect.fail(missingScope(scope));
        return yield* k(caller, granted);
      }),
    );
  });
