/** A withdrawn image can recover an admitted allocation, never authorize another provider create. */
import type { Named } from "@gdp-ts/core";
import { Effect } from "effect";
import { CreatedVm } from "../api.ts";
import type { VmImageSelection } from "../api/images.ts";
import { scopedCreationKey } from "../auth/idempotency-key.ts";
import type { Principal } from "../domain/principal.ts";
import { conflict, unavailable, vmNotFound, type Conflict, type Forbidden, type NotFound } from "../errors.ts";
import { TenantLimits } from "../limits/service.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { reconcileCreation } from "./creation-recovery.ts";
import { replayVm } from "./replay-vm.ts";

export const recoverWithdrawnImage = <C>(
  caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, rawKey: string | undefined,
  clientFingerprint: string | undefined, image: VmImageSelection, originalError: Conflict | Forbidden | NotFound,
) => Effect.gen(function* () {
  if (rawKey === undefined || clientFingerprint === undefined || (originalError._tag !== "Conflict" && originalError._tag !== "NotFound")) return yield* Effect.fail(originalError);
  const key = yield* scopedCreationKey(caller.value, rawKey);
  const record = yield* (yield* TenantLimits).inspect(caller.value.tenantId, key).pipe(Effect.mapError(() => unavailable()));
  // Legacy journals lack this binding; their explicit by-key reconciliation remains available.
  if (record?.clientFingerprint === undefined) return yield* Effect.fail(originalError);
  if (record.clientFingerprint !== clientFingerprint) return yield* Effect.fail(conflict("This Idempotency-Key was already used with a different request"));
  const prior = record.progress;
  if (prior.phase === "cancelled" || (prior.phase === "creating" && prior.cancelRequested === true)) return yield* Effect.fail(conflict("This VM creation was cancelled; inspect its status"));
  if (prior.phase !== "creating" && prior.phase !== "done") return yield* Effect.fail(originalError);
  const status = yield* reconcileCreation(caller, scope, rawKey, prior.vmId);
  if (status.id !== prior.vmId) return yield* Effect.fail(unavailable());
  if (status.state === "cancelling" || status.state === "cancelled") return yield* Effect.fail(conflict("This VM creation was cancelled; inspect its status"));
  if (status.state === "deleted") return yield* Effect.fail(vmNotFound());
  if (status.state !== "committed" || status.receipt?.bootImage === undefined
    || status.receipt.bootImage.id !== image.id || status.receipt.bootImage.revision !== image.revision) return yield* Effect.fail(unavailable());
  const vm = yield* replayVm(caller, scope, prior.vmId);
  return new CreatedVm({ ...vm, bootImage: status.receipt.bootImage,
    ...(status.receipt.initialNetwork === undefined ? {} : { initialNetwork: status.receipt.initialNetwork }),
  });
}).pipe(Effect.uninterruptible);
