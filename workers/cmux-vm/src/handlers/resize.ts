import { Effect } from "effect";
import type { ResizeVmRequest } from "../api.ts";
import { conflict, QuotaExceeded, unavailable, vmNotFound } from "../errors.ts";
import { tenantMayGrow } from "../proofs/tenant-may-grow.ts";
import { resourceFloorsReached, UpstreamClient, type UpstreamError } from "../upstream/client.ts";
import { withOwnedVm } from "./common.ts";
import { idempotent } from "./idempotency.ts";
import { toVm } from "./vm-view.ts";

const onResize = (error: UpstreamError) => error.status === 404 ? vmNotFound()
  : error.status === 400 || error.status === 409 ? conflict("The VM cannot grow to the requested resources now; disk growth requires a running VM")
  : error.status === 429 ? new QuotaExceeded({ message: "VM capacity is exhausted for now; retry later", retryAfterSeconds: 60, budget: "capacity" })
  : unavailable();

export const resizeVm = (vmId: string, payload: ResizeVmRequest, key: string | undefined) =>
  withOwnedVm(vmId, "vm:write", "write", (caller, vm, proofs) => Effect.gen(function* () {
    const mayGrow = yield* tenantMayGrow(caller).pipe(Effect.catchTag("EntitlementUnavailable", () => Effect.fail(unavailable())));
    const upstream = yield* UpstreamClient;
    const size = payload.resources;
    const read = () => upstream.getVmForWrite(vm, proofs).pipe(Effect.mapError(onResize),
      Effect.flatMap((current) => resourceFloorsReached(current, size) ? Effect.succeed(toVm(vm.value, proofs.owns, current)) : Effect.fail(unavailable())));

    return yield* idempotent(caller.value, key, ["resizeVm", vm.value, size.vcpus ?? null, size.memoryMib ?? null, size.diskMib ?? null],
      () => upstream.resizeVm(vm, { ...proofs, mayGrow }, size).pipe(Effect.mapError(onResize), Effect.map((current) => toVm(vm.value, proofs.owns, current))),
      read,
    ).pipe(Effect.uninterruptible);
  }));
