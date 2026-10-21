import { Effect } from "effect";
import { RetiredVm } from "../api.ts";
import { unavailable, vmNotFound } from "../errors.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { withOwnedVm } from "./common.ts";

export const retireVm = (vmId: string) => withOwnedVm(vmId, "vm:write", "write", (_caller, vm, proofs) => Effect.gen(function* () {
  const upstream = yield* UpstreamClient;
  const retired = yield* upstream.retireVm(vm, proofs).pipe(Effect.mapError((error) => error.status === 404 ? vmNotFound() : unavailable()));
  // Keep a separate receipt so an older API's ordinary pause cannot be mistaken for retirement.
  if (retired.maxRunTotalSeconds !== 0 || (retired.state !== "paused" && retired.state !== "stopped")) return yield* Effect.fail(unavailable());
  return new RetiredVm({ id: vm.value, state: retired.state, retired: true });
}));
