/**
 * VM endpoints. Each handler names the caller and the resource, proves scope
 * and ownership, and only then calls the upstream client, which does not
 * compile without those proofs. Scope is checked before ownership, so a 403
 * never depends on which resource was asked for, and a resource the caller's
 * tenant does not own is always 404.
 */
import { HttpApiBuilder } from "@effect/platform";
import { name, type Named } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { CmuxVmApi, Vm, type VmState } from "../api.ts";
import { CurrentPrincipal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import { missingScope, notImplemented, unavailable, vmNotFound } from "../errors.ts";
import { parseVmId, type VmId } from "../lib/ids.ts";
import { keyHasScope, type KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantOwnsVm, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient, type UpstreamVm } from "../upstream/client.ts";

const KNOWN_STATES: ReadonlyArray<VmState> = ["starting", "running", "pausing", "paused", "stopped"];

const stateOf = (state: string): VmState => KNOWN_STATES.find((known) => known === state) ?? "unknown";

/** The public view: the cmux id plus an allowlist of provider fields. Provider ids never appear. */
export const toVm = (id: VmId, upstream: UpstreamVm): Vm =>
  new Vm({
    id,
    state: stateOf(upstream.state),
    resources: {
      vcpus: upstream.resources.cpu,
      memoryMib: upstream.resources.memory,
      diskMib: upstream.resources.storage,
    },
    idleTimeoutSeconds: upstream.idleTimeoutSeconds ?? null,
    createdAt: upstream.createdAt,
    updatedAt: upstream.updatedAt,
  });

/** Proves `scope` for the caller, without reference to any resource. */
const requireScope = (scope: Scope) =>
  Effect.flatMap(CurrentPrincipal, (principal) =>
    name(principal, (caller) => (keyHasScope(caller, scope) === null ? Effect.fail(missingScope(scope)) : Effect.void)),
  );

/** Logs which dependency failed (operation tag only, never ids or causes) and answers 503. */
const storeUnavailable = (error: { readonly operation: string }) =>
  Effect.logWarning("cmux-vm dependency unavailable").pipe(
    Effect.annotateLogs({ operation: error.operation }),
    Effect.zipRight(Effect.fail(unavailable())),
  );

/**
 * Resolves a public VM id for the caller: proves `scope` (before looking at
 * the id at all), then proves the caller's tenant owns the VM, then runs `k`
 * with both proofs.
 */
const withOwnedVm = <const S extends Scope, A, E, R>(
  rawId: string,
  scope: S,
  k: <C, V>(
    vm: Named<V, VmId>,
    proofs: { readonly owns: TenantOwnsResource<C, V>; readonly scope: KeyHasScope<C, S> },
  ) => Effect.Effect<A, E, R>,
) =>
  Effect.flatMap(CurrentPrincipal, (principal) =>
    name(principal, (caller) =>
      Effect.gen(function* () {
        const granted = keyHasScope(caller, scope);
        if (granted === null) return yield* Effect.fail(missingScope(scope));
        const parsed = parseVmId(rawId);
        if (Option.isNone(parsed)) return yield* Effect.fail(vmNotFound());
        return yield* name(parsed.value, (vm) =>
          Effect.gen(function* () {
            const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.catchAll(storeUnavailable));
            if (owns === null) return yield* Effect.fail(vmNotFound());
            return yield* k(vm, { owns, scope: granted });
          }),
        );
      }),
    ),
  );

export const vmsHandlers = HttpApiBuilder.group(CmuxVmApi, "vms", (handlers) =>
  handlers
    .handle("getVm", ({ path }) =>
      Effect.flatMap(UpstreamClient, (upstream) =>
        withOwnedVm(path.vmId, "vm:read", (vm, proofs) =>
          upstream.getVm(vm, proofs).pipe(
            Effect.map((found) => toVm(vm.value, found)),
            Effect.catchAll((error) =>
              error.status === 404 ? Effect.fail(vmNotFound()) : storeUnavailable({ operation: `upstream.${error.operation}.${error.status ?? "network"}` }),
            ),
          ),
        ),
      ),
    )
    // The rest of the lifecycle is published for client generation and served in S2.
    .handle("createVm", () => requireScope("vm:write").pipe(Effect.zipRight(Effect.fail(notImplemented("createVm")))))
    .handle("listVms", () => requireScope("vm:read").pipe(Effect.zipRight(Effect.fail(notImplemented("listVms")))))
    .handle("startVm", ({ path }) => withOwnedVm(path.vmId, "vm:write", () => Effect.fail(notImplemented("startVm"))))
    .handle("stopVm", ({ path }) => withOwnedVm(path.vmId, "vm:write", () => Effect.fail(notImplemented("stopVm"))))
    .handle("pauseVm", ({ path }) => withOwnedVm(path.vmId, "vm:write", () => Effect.fail(notImplemented("pauseVm"))))
    .handle("resumeVm", ({ path }) => withOwnedVm(path.vmId, "vm:write", () => Effect.fail(notImplemented("resumeVm"))))
    .handle("forkVm", ({ path }) => withOwnedVm(path.vmId, "vm:write", () => Effect.fail(notImplemented("forkVm"))))
    .handle("deleteVm", ({ path }) => withOwnedVm(path.vmId, "vm:write", () => Effect.fail(notImplemented("deleteVm")))),
);
