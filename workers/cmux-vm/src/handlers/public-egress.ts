/** Read, allow or revoke an existing VM's public egress (api/public-egress.ts). */
import { Effect } from "effect";
import { VmPublicEgress } from "../api/public-egress.ts";
import { unavailable, vmNotFound } from "../errors.ts";
import { UpstreamClient, type UpstreamError } from "../upstream/client.ts";
import { withOwnedVm } from "./common.ts";

const onUpstream = (error: UpstreamError) =>
  error.status === 404 ? vmNotFound() : unavailable(error);

export const getVmPublicEgress = (vmId: string) =>
  withOwnedVm(vmId, "vm:network", "read", (_caller, vm, proofs) => Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    const publicEgress = yield* upstream.readVmPublicEgress(vm, proofs).pipe(Effect.mapError(onUpstream));
    return new VmPublicEgress({ id: vm.value, publicEgress });
  }));

export const allowVmPublicEgress = (vmId: string) =>
  withOwnedVm(vmId, "vm:network", "write", (_caller, vm, proofs) => Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    yield* upstream.allowVmPublicEgress(vm, proofs).pipe(Effect.mapError(onUpstream));
    return new VmPublicEgress({ id: vm.value, publicEgress: true });
  }));

export const revokeVmPublicEgress = (vmId: string) =>
  withOwnedVm(vmId, "vm:network", "write", (_caller, vm, proofs) => Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    yield* upstream.revokeVmPublicEgress(vm, proofs).pipe(Effect.mapError(onUpstream));
    return new VmPublicEgress({ id: vm.value, publicEgress: false });
  }));
