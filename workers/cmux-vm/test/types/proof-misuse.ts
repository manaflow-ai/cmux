import { UpstreamSnapshots } from "../../src/upstream/snapshots.ts";
import { authorizedSnapshotCapture, forkSnapshotAccess } from "../../src/proofs/snapshot-capture.ts";
import { pendingVmCreation, cancellingVmCreation } from "../../src/proofs/vm-creation.ts";
import { pendingMeshCreation } from "../../src/proofs/mesh-creation.ts";
import { tenantMayCreateMesh } from "../../src/proofs/mesh-may-create.ts";
import { UpstreamMesh } from "../../src/upstream/mesh.ts";
import type { MeshId } from "../../src/lib/ids.ts";
/**
 * Compile-time checks, enforced by `tsc` (this file is in tsconfig's include).
 * Each `@ts-expect-error` line is a call the type checker must refuse; if one
 * starts compiling, `tsc` fails with "Unused '@ts-expect-error' directive".
 * Never executed.
 */
import { name, type Named } from "@gdp-ts/core";
import { Effect, Redacted } from "effect";
import type { Principal } from "../../src/domain/principal.ts";
import type { VmId } from "../../src/lib/ids.ts";
import { keyHasScope, type KeyHasScope } from "../../src/proofs/key-has-scope.ts";
import { tenantMayGrow } from "../../src/proofs/tenant-may-grow.ts";
import { tenantMayCreate } from "../../src/proofs/tenant-may-create.ts";
import { vmImageAllowed } from "../../src/proofs/vm-image.ts";
import { vmNetworkAllowed } from "../../src/proofs/vm-network.ts";
import { tenantOwnsVm } from "../../src/proofs/tenant-owns-resource.ts";
import type { CreateVmSpec } from "../../src/upstream/client.ts";
import { UpstreamClient } from "../../src/upstream/client.ts";

const journalFixture: CreateVmSpec["journal"] = {
  context: null, beforeSend: () => Effect.void, beginSend: () => Effect.succeed("send"),
  rejected: () => Effect.void, active: Effect.void,
};

export const meshCreateMisuse = (principal: Principal, meshA: MeshId, meshB: MeshId) => Effect.gen(function* () {
  const upstream = yield* UpstreamMesh;
  yield* name(principal, meshA, meshB, (caller, a, b) => Effect.gen(function* () {
    const scope = keyHasScope(caller, "mesh:write"), pending = yield* pendingMeshCreation(caller, a, "digest", "holder");
    const decision = yield* tenantMayCreateMesh(caller);
    if (scope === null || pending === null || decision._tag !== "granted") return;
    const mayCreate = decision.proof;
    yield* upstream.recoverNetwork(a, { scope, pending });
    yield* upstream.createJournalledNetwork(a, { scope, pending, mayCreate });
    // @ts-expect-error recovery authority for A cannot inspect B's provider network
    yield* upstream.recoverNetwork(b, { scope, pending });
    // @ts-expect-error a scope and quota alone cannot resume an uncommitted network
    yield* upstream.createJournalledNetwork(a, { scope, mayCreate });
    // @ts-expect-error recovery authority alone does not permit a new allocation
    yield* upstream.createJournalledNetwork(a, { scope, pending });
  }));
});

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
        yield* upstream.instanceFingerprint(a, { owns: ownsA, scope: read });
        // @ts-expect-error ownership of A cannot disclose B's canonical identity
        yield* upstream.instanceFingerprint(b, { owns: ownsA, scope: read });
        // @ts-expect-error write scope alone does not grant identity reads
        yield* upstream.instanceFingerprint(a, { owns: ownsA, scope: write });

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
        // @ts-expect-error vm:read does not authorize file metadata
        yield* upstream.statFile(a, { owns: ownsA, scope: read }, "/");
        const files = keyHasScope(caller, "vm:files");
        if (files !== null) {
          yield* upstream.statFile(a, { owns: ownsA, scope: files }, "/");
          // @ts-expect-error VM A's ownership does not authorize VM B's file metadata
          yield* upstream.statFile(b, { owns: ownsA, scope: files }, "/");
        }
        // @ts-expect-error a create needs a TenantMayCreate proof
        yield* upstream.createVm(caller, { cmuxId: vmA, idleTimeoutSeconds: 300, environment: "local", journal: journalFixture }, { scope: write });
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
      const spec = { cmuxId: vmId, idleTimeoutSeconds: 300, environment: "local", journal: journalFixture };
      const network = yield* vmNetworkAllowed(caller, { publicEgress: true, httpsProxies: [] });
      const otherNetwork = yield* vmNetworkAllowed(other, { publicEgress: true, httpsProxies: [] });
      yield* upstream.createVm(caller, spec, { scope, mayCreate: decision.proof, network });
      // @ts-expect-error allocation requires a durable journal even with every other proof
      yield* upstream.createVm(caller, { cmuxId: vmId, idleTimeoutSeconds: 300, environment: "local" }, { scope, mayCreate: decision.proof, network });
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
    const spec = { cmuxId: vmId, idleTimeoutSeconds: 300, environment: "local", journal: journalFixture };
    const image = yield* vmImageAllowed(caller, { id: "cloud-standard", revision: "r1" });
    const otherImage = yield* vmImageAllowed(other, { id: "cloud-standard", revision: "r1" });
    yield* upstream.createVm(caller, spec, { scope, mayCreate: decision.proof, image });
    // @ts-expect-error another caller's image authority cannot authorize this create
    yield* upstream.createVm(caller, spec, { scope, mayCreate: decision.proof, image: otherImage });
    // @ts-expect-error raw image input cannot bypass the proof argument
    yield* upstream.createVm(caller, { ...spec, image: { id: "cloud-standard", revision: "r1" } }, { scope, mayCreate: decision.proof });
  })));
});

export const resizeMisuse = (principal: Principal, vmA: VmId, vmB: VmId) => Effect.gen(function* () {
  const upstream = yield* UpstreamClient;
  yield* name(principal, vmA, vmB, (caller, a, b) => Effect.gen(function* () {
    const owns = yield* tenantOwnsVm(caller, a);
    const scope = keyHasScope(caller, "vm:write");
    const read = keyHasScope(caller, "vm:read");
    const mayGrow = yield* tenantMayGrow(caller);
    if (owns === null || scope === null || read === null) return;
    yield* upstream.resizeVm(a, { owns, scope, mayGrow }, { vcpus: 8 });
    yield* upstream.retireVm(a, { owns, scope });
    // @ts-expect-error VM A's ownership cannot retire VM B
    yield* upstream.retireVm(b, { owns, scope });
    // @ts-expect-error read permission cannot retire a VM
    yield* upstream.retireVm(a, { owns, scope: read });
    // @ts-expect-error VM A's ownership cannot grow VM B
    yield* upstream.resizeVm(b, { owns, scope, mayGrow }, { vcpus: 8 });
    // @ts-expect-error read permission cannot resize a VM
    yield* upstream.resizeVm(a, { owns, scope: read, mayGrow }, { vcpus: 8 });
    // @ts-expect-error ownership and scope do not establish the tenant's VM plan
    yield* upstream.resizeVm(a, { owns, scope }, { vcpus: 8 });
    yield* name(principal, (other) => Effect.gen(function* () {
      const otherPlan = yield* tenantMayGrow(other);
      // @ts-expect-error another caller's entitlement cannot authorize this resize
      yield* upstream.resizeVm(a, { owns, scope, mayGrow: otherPlan }, { vcpus: 8 });
    }));
  }));
});


export const creationRecoveryMisuse = (principal: Principal, vmA: VmId, vmB: VmId) => Effect.gen(function* () {
  const upstream = yield* UpstreamClient;
  yield* name(principal, vmA, vmB, (caller, a, b) => Effect.gen(function* () {
    const pending = yield* pendingVmCreation(caller, a, "intent");
    const scope = keyHasScope(caller, "vm:write");
    const read = keyHasScope(caller, "vm:read");
    if (pending === null || scope === null || read === null) return;
    yield* upstream.recoverCreation(caller, a, { pending, scope });
    // @ts-expect-error VM A's intent cannot authorize recovering VM B
    yield* upstream.recoverCreation(caller, b, { pending, scope });
    // @ts-expect-error read scope cannot record recovered ownership
    yield* upstream.recoverCreation(caller, a, { pending, scope: read });
    // @ts-expect-error ordinary write permission cannot adopt a provider allocation
    yield* upstream.recoverCreation(caller, a, { scope });
  }));
});


export const cancellationMisuse = (principal: Principal, vmA: VmId, vmB: VmId) => Effect.gen(function* () {
  const upstream = yield* UpstreamClient;
  yield* name(principal, vmA, vmB, (caller, a, b) => Effect.gen(function* () {
    const cancelling = yield* cancellingVmCreation(caller, a, "cancel-intent");
    const owns = yield* tenantOwnsVm(caller, a), scope = keyHasScope(caller, "vm:write"), read = keyHasScope(caller, "vm:read");
    if (cancelling === null || owns === null || scope === null || read === null) return;
    yield* upstream.inspectCancellingCreation(caller, a, { cancelling, scope });
    yield* upstream.deleteCancellingCreation(caller, a, { cancelling, owns, scope });
    // @ts-expect-error VM A's cancellation proof cannot delete VM B
    yield* upstream.deleteCancellingCreation(caller, b, { cancelling, owns, scope });
    // @ts-expect-error read authority does not authorize cancellation cleanup
    yield* upstream.deleteCancellingCreation(caller, a, { cancelling, owns, scope: read });
    // @ts-expect-error write authority and ownership alone cannot bypass the cancellation fence
    yield* upstream.deleteCancellingCreation(caller, a, { owns, scope });
  }));
});


// Snapshot capture recovery requires the exact current caller, snapshot, and trusted journal proof.
import type { AuthorizedSnapshotCapture } from "../../src/proofs/snapshot-capture.ts";
import type { UpstreamSnapshotsService } from "../../src/upstream/snapshots.ts";
import type { SnapshotId as CaptureSnapshotId } from "../../src/lib/ids.ts";
declare const captures: UpstreamSnapshotsService;
declare const captured: Named<"captured", CaptureSnapshotId>;
declare const captureProof: AuthorizedSnapshotCapture<"capture-caller", "captured">;
declare const wrongCapture: AuthorizedSnapshotCapture<"capture-caller", "other-snapshot">;
declare const captureScope: KeyHasScope<"capture-caller", "snapshot:write">;
// @ts-expect-error recovery cannot run without durable capture authority
captures.recoverCapture(captured, { scope: captureScope });
// @ts-expect-error capture authority for another snapshot cannot authorize this lookup
captures.recoverCapture(captured, { scope: captureScope, capture: wrongCapture });
captures.recoverCapture(captured, { scope: captureScope, capture: captureProof });

// Fork delegation cannot turn a general VM write key into snapshot write authority.
export const forkSnapshotMisuse = (principal: Principal, first: import("../../src/lib/ids.ts").SnapshotId, second: import("../../src/lib/ids.ts").SnapshotId) => Effect.gen(function* () {
  const snapshots = yield* UpstreamSnapshots;
  yield* name(principal, first, second, (caller, a, b) => Effect.gen(function* () {
    const scope = keyHasScope(caller, "vm:write");
    if (scope === null) return;
    const capture = yield* authorizedSnapshotCapture(caller, a);
    const access = yield* forkSnapshotAccess(caller, a, "retained-fork", scope);
    yield* snapshots.recoverCapture(a, { capture, scope: access });
    // @ts-expect-error VM write scope does not authorize an arbitrary snapshot.
    yield* snapshots.recoverCapture(a, { capture, scope });
    // @ts-expect-error Fork A's delegation and capture proof cannot inspect snapshot B.
    yield* snapshots.recoverCapture(b, { capture, scope: access });
  }));
});
