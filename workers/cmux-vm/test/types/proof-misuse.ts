/**
 * Compile-time checks, enforced by `tsc` (this file is in tsconfig's include).
 * Each `@ts-expect-error` line is a call the type checker must refuse; if one
 * starts compiling, `tsc` fails with "Unused '@ts-expect-error' directive".
 * Never executed.
 */
import { name } from "@gdp-ts/core";
import { Effect, Redacted } from "effect";
import type { Principal } from "../../src/domain/principal.ts";
import type { VmId } from "../../src/lib/ids.ts";
import { keyHasScope } from "../../src/proofs/key-has-scope.ts";
import { tenantMayCreate } from "../../src/proofs/tenant-may-create.ts";
import { vmImageAllowed } from "../../src/proofs/vm-image.ts";
import { vmNetworkAllowed } from "../../src/proofs/vm-network.ts";
import { tenantOwnsVm } from "../../src/proofs/tenant-owns-resource.ts";
import { UpstreamClient } from "../../src/upstream/client.ts";

export const misuse = (principal: Principal, vmA: VmId, vmB: VmId) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;

    yield* name(principal, vmA, vmB, (caller, a, b) =>
      Effect.gen(function* () {
        const read = keyHasScope(caller, "vm:read");
        const write = keyHasScope(caller, "vm:write");
        const ownsA = yield* tenantOwnsVm(caller, a);
        if (read === null || write === null || ownsA === null) return;

        // The honest call compiles.
        yield* upstream.getVm(a, { owns: ownsA, scope: read });

        // @ts-expect-error no proofs at all
        yield* upstream.getVm(a);
        // @ts-expect-error a proof about VM A does not authorize VM B
        yield* upstream.getVm(b, { owns: ownsA, scope: read });
        // @ts-expect-error vm:write is not vm:read
        yield* upstream.getVm(a, { owns: ownsA, scope: write });
        // @ts-expect-error a raw id is not a named id
        yield* upstream.getVm(vmA, { owns: ownsA, scope: read });

        // S2: each mutation demands its own scope about the same caller and VM.
        yield* upstream.pauseVm(a, { owns: ownsA, scope: write });
        // @ts-expect-error vm:read cannot pause
        yield* upstream.pauseVm(a, { owns: ownsA, scope: read });
        // @ts-expect-error vm:read cannot delete
        yield* upstream.deleteVm(a, { owns: ownsA, scope: read });
        // @ts-expect-error a proof about VM A does not delete VM B
        yield* upstream.deleteVm(b, { owns: ownsA, scope: write });
        // @ts-expect-error vm:write is not vm:exec
        yield* upstream.exec(a, { owns: ownsA, scope: write }, { command: "true" });
        // @ts-expect-error vm:write is not vm:files
        yield* upstream.listFiles(a, { owns: ownsA, scope: write }, "/");
        // @ts-expect-error a create needs a TenantMayCreate proof
        yield* upstream.createVm(caller, { cmuxId: vmA, idleTimeoutSeconds: 300, environment: "local" }, { scope: write });
      }),
    );

    // Proofs about another caller do not mix: a second name for the same principal is a different caller.
    yield* name(principal, vmA, (first, a) =>
      name(principal, (second) =>
        Effect.gen(function* () {
          const ownsA = yield* tenantOwnsVm(first, a);
          const readSecond = keyHasScope(second, "vm:read");
          if (ownsA === null || readSecond === null) return;
          // @ts-expect-error ownership by one caller and scope of another do not combine
          yield* upstream.getVm(a, { owns: ownsA, scope: readSecond });
        }),
      ),
    );
  });

/** Network authority is bound to the same caller as the quota and write proofs. */
export const networkMisuse = (principal: Principal, vmId: VmId) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    yield* name(principal, (caller) => name(principal, (other) => Effect.gen(function* () {
      const scope = keyHasScope(caller, "vm:write");
      const networkScope = keyHasScope(caller, "vm:network");
      const decision = yield* tenantMayCreate(caller, "vm");
      if (scope === null || networkScope === null || decision._tag !== "granted") return;
      const spec = { cmuxId: vmId, idleTimeoutSeconds: 300, environment: "local" };
      const network = yield* vmNetworkAllowed(caller, { publicEgress: true, httpsProxies: [] });
      const otherNetwork = yield* vmNetworkAllowed(other, { publicEgress: true, httpsProxies: [] });
      yield* upstream.createVm(caller, spec, { scope, mayCreate: decision.proof, network });
      // @ts-expect-error a network scope alone is not a checked network policy
      yield* upstream.createVm(caller, spec, { scope, mayCreate: decision.proof, network: networkScope });
      // @ts-expect-error another caller's network proof cannot authorize this create
      yield* upstream.createVm(caller, spec, { scope, mayCreate: decision.proof, network: otherNetwork });
      // @ts-expect-error raw network intent cannot bypass the proof argument
      yield* upstream.createVm(caller, { ...spec, initialNetwork: { publicEgress: true } }, { scope, mayCreate: decision.proof });
    })));
  });

export const proxyMisuse = (principal: Principal, vmA: VmId, vmB: VmId) => Effect.gen(function* () {
  const upstream = yield* UpstreamClient;
  yield* name(principal, vmA, vmB, (caller, a, b) => Effect.gen(function* () {
    const owns = yield* tenantOwnsVm(caller, a);
    const scope = keyHasScope(caller, "vm:network");
    const write = keyHasScope(caller, "vm:write");
    if (owns === null || scope === null || write === null) return;
    const network = yield* vmNetworkAllowed(caller, { publicEgress: false, httpsProxies: [{
      hostname: "api.cmux.internal", destination: "https://api.example.test", headers: Redacted.make({}),
    }] });
    yield* upstream.replaceVmHttpsProxy(a, { owns, scope, network });
    // @ts-expect-error VM A's ownership does not authorize changing VM B's proxy
    yield* upstream.replaceVmHttpsProxy(b, { owns, scope, network });
    // @ts-expect-error ordinary VM write permission cannot change network policy
    yield* upstream.replaceVmHttpsProxy(a, { owns, scope: write, network });
    // @ts-expect-error network scope alone does not prove an approved replacement policy
    yield* upstream.replaceVmHttpsProxy(a, { owns, scope });
    yield* name(principal, (other) => Effect.gen(function* () {
      const otherNetwork = yield* vmNetworkAllowed(other, { publicEgress: false, httpsProxies: [] });
      // @ts-expect-error another caller's network policy does not authorize this VM
      yield* upstream.replaceVmHttpsProxy(a, { owns, scope, network: otherNetwork });
    }));
  }));
});

export const imageMisuse = (principal: Principal, vmId: VmId) => Effect.gen(function* () {
  const upstream = yield* UpstreamClient;
  yield* name(principal, (caller) => name(principal, (other) => Effect.gen(function* () {
    const scope = keyHasScope(caller, "vm:write");
    const decision = yield* tenantMayCreate(caller, "vm");
    if (scope === null || decision._tag !== "granted") return;
    const spec = { cmuxId: vmId, idleTimeoutSeconds: 300, environment: "local" };
    const image = yield* vmImageAllowed(caller, { id: "cloud-standard", revision: "r1" });
    const otherImage = yield* vmImageAllowed(other, { id: "cloud-standard", revision: "r1" });
    yield* upstream.createVm(caller, spec, { scope, mayCreate: decision.proof, image });
    // @ts-expect-error another caller's image authority cannot authorize this create
    yield* upstream.createVm(caller, spec, { scope, mayCreate: decision.proof, image: otherImage });
    // @ts-expect-error raw image input cannot bypass the proof argument
    yield* upstream.createVm(caller, { ...spec, image: { id: "cloud-standard", revision: "r1" } }, { scope, mayCreate: decision.proof });
  })));
});
