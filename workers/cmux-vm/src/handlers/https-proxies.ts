import { Effect } from "effect";
import { VmHttpsProxyReceipt, type ReplaceVmHttpsProxyRequest } from "../api/https-proxies.ts";
import { conflict, NotFound, unavailable } from "../errors.ts";
import { vmNetworkAllowed, vmNetworkEvidenceOf } from "../proofs/vm-network.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { withOwnedVm } from "./common.ts";
import { idempotent } from "./idempotency.ts";

const missing = () => new NotFound({ message: "HTTPS proxy not found" });

export const replaceVmHttpsProxy = (vmId: string, hostname: string, payload: ReplaceVmHttpsProxyRequest, key: string | undefined) =>
  withOwnedVm(vmId, "vm:network", "write", (caller, vm, proofs) => Effect.gen(function* () {
    const network = yield* vmNetworkAllowed(caller, { publicEgress: false, httpsProxies: [{ hostname, ...payload }] });
    const evidence = vmNetworkEvidenceOf(network);
    const acceptedHost = evidence.receipt.httpsProxyHosts[0];
    if (acceptedHost === undefined) return yield* Effect.fail(unavailable());
    const receipt = () => new VmHttpsProxyReceipt({ id: vm.value, hostname: acceptedHost });
    const upstream = yield* UpstreamClient;
    return yield* idempotent(caller.value, key, ["replaceVmHttpsProxy", vm.value, evidence.fingerprint],
      () => Effect.gen(function* () {
        const result = yield* upstream.replaceVmHttpsProxy(vm, { ...proofs, network }).pipe(
          Effect.mapError((error) => error.status === 404 ? missing() : unavailable()),
        );
        if (result === "missing") return yield* Effect.fail(missing());
        if (result === "ambiguous") return yield* Effect.fail(conflict("More than one HTTPS proxy rule matches this VM and hostname"));
        return receipt();
      }),
      () => Effect.succeed(receipt()),
    );
  }));
