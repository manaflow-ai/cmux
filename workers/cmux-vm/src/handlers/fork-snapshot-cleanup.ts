/** Best-effort cleanup of only the caller-owned intermediate fork snapshot. */
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { OwnershipStore } from "../db/stores.ts";
import type { Principal } from "../domain/principal.ts";
import { parseSnapshotId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantOwnsSnapshot } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient } from "../upstream/client.ts";

export const cleanupForkSnapshot = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, snapshotId: string) => Effect.gen(function* () {
  const parsed = parseSnapshotId(snapshotId);
  if (Option.isNone(parsed)) return;
  yield* name(parsed.value, (snapshot) => Effect.gen(function* () {
    const owns = yield* tenantOwnsSnapshot(caller, snapshot);
    if (owns === null) return;
    yield* (yield* UpstreamClient).deleteSnapshot(snapshot, { owns, scope });
    yield* (yield* OwnershipStore).markDeleted(caller.value.tenantId, "snapshot", snapshot.value, new Date(yield* Clock.currentTimeMillis));
  }));
}).pipe(Effect.catchAll(() => Effect.void));
