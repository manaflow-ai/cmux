/**
 * Resolves a public snapshot id for the caller, in the order every endpoint
 * uses (handlers/common.ts does the same for VMs): prove the scope (a 403
 * never depends on which snapshot was asked for), apply the tenant's rate
 * limit, then prove the caller's tenant owns the snapshot (a malformed id, a
 * missing one and another tenant's are the same 404), then run `k`.
 */
import { name, type Named } from "@gdp-ts/core";
import { Effect, Option, Schema } from "effect";
import { CurrentPrincipal, type Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import { missingScope, NotFound } from "../errors.ts";
import { SnapshotId } from "../lib/ids.ts";
import type { RateClass } from "../limits/ledger.ts";
import { keyHasScope, type KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantOwnsSnapshot, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { dependencyDown, rateLimit } from "./common.ts";

export const snapshotNotFound = () => new NotFound({ message: "Snapshot not found" });

const parseSnapshotId = Schema.decodeUnknownOption(SnapshotId);

export const withOwnedSnapshot = <const S extends Scope, A, E, R>(
  rawId: string,
  scope: S,
  rateClass: RateClass,
  k: <C, V>(
    caller: Named<C, Principal>,
    snapshot: Named<V, SnapshotId>,
    proofs: { readonly owns: TenantOwnsResource<C, V>; readonly scope: KeyHasScope<C, S> },
  ) => Effect.Effect<A, E, R>,
) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    return yield* name(principal, (caller) =>
      Effect.gen(function* () {
        const granted = keyHasScope(caller, scope);
        if (granted === null) return yield* Effect.fail(missingScope(scope));
        yield* rateLimit(principal, rateClass);
        const parsed = parseSnapshotId(rawId);
        if (Option.isNone(parsed)) return yield* Effect.fail(snapshotNotFound());
        return yield* name(parsed.value, (snapshot) =>
          Effect.gen(function* () {
            const owns = yield* tenantOwnsSnapshot(caller, snapshot).pipe(Effect.catchAll(dependencyDown("ownership.find")));
            if (owns === null) return yield* Effect.fail(snapshotNotFound());
            return yield* k(caller, snapshot, { owns, scope: granted });
          }),
        );
      }),
    );
  });
