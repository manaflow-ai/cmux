/**
 * The rules that make an agent key's sandboxes its own: the labels every VM it
 * creates gets, its live-VM and $/h budget, and revoking a VM's client sessions
 * when the VM goes. Shared by the VM handlers, the agent handlers and the reaper.
 */
import type { Named } from "@gdp-ts/core";
import { Clock, Effect } from "effect";
import { MAX_LABELS, type CreateVmRequest } from "../api.ts";
import { AgentStore } from "../db/agents.ts";
import { estimatedUsdPerHour, sizeOfCreate } from "../domain/agents.ts";
import type { Principal } from "../domain/principal.ts";
import { badRequest, Forbidden, QuotaExceeded, unavailable } from "../errors.ts";
import type { TenantId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { visitOwnedVms } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient, type SizeRequest } from "../upstream/client.ts";

const describeLabels = (labels: Readonly<Record<string, string>>) =>
  Object.entries(labels)
    .map(([key, value]) => `${key}=${value}`)
    .join(", ");

/** An agent key's create, with its labels added; a label that names another agent (or drops the issuer's) is 403. */
export const withAgentLabels = (principal: Principal, requested: CreateVmRequest) =>
  Effect.gen(function* () {
    const required = principal.requiredLabels;
    if (principal.agent === undefined || required === undefined) return requested;
    const asked = requested.labels ?? {};
    if (Object.entries(required).some(([key, value]) => key in asked && asked[key] !== value)) {
      return yield* Effect.fail(new Forbidden({ message: `This agent key creates only VMs labelled ${describeLabels(required)}` }));
    }
    const labels = { ...asked, ...required };
    if (Object.keys(labels).length > MAX_LABELS) {
      return yield* Effect.fail(badRequest(`An agent's VM carries ${Object.keys(required).length} labels of its own; ask for at most ${MAX_LABELS - Object.keys(required).length}`));
    }
    const merged: CreateVmRequest = { ...requested, labels };
    return merged;
  });

/**
 * A caller on a run cap (a CI trust row) creates only VMs that pause within the cap and are deleted as soon as they
 * stop: a smaller run cap it asks for stands, no cap or a longer one becomes the cap, and auto-delete is always 0.
 */
/**
 * A caller on a run cap (a CI trust row) creates VMs only at the default or an approved image's size: it cannot ask
 * for resources, cannot boot a tenant snapshot (whose size it would not know), and cannot resize (resize.ts). Its spend is then at most maxVms VMs of a size the operator chose, and the team
 * quota (maxVms) is admitted atomically, so concurrent creates cannot pass the read-then-create budget check together.
 */
export const ciSizeAllowed = (principal: Principal, requested: Pick<CreateVmRequest, "resources" | "snapshotId">) =>
  principal.maxRunSeconds !== undefined && (requested.resources !== undefined || requested.snapshotId !== undefined)
    ? Effect.fail(new Forbidden({ message: "A CI job creates VMs from the base or an approved image at its own size; omit resources and snapshotId" }))
    : Effect.void;

export const withRunCap = (principal: Principal, requested: CreateVmRequest): CreateVmRequest => {
  const cap = principal.maxRunSeconds;
  if (cap === undefined) return requested;
  const asked = requested.maxRunSeconds;
  return { ...requested, maxRunSeconds: asked !== undefined && asked > 0 && asked < cap ? asked : cap, autoDeleteSeconds: 0 };
};

/**
 * Whether one more VM of `size` fits the agent key's budget: fewer live VMs than
 * maxVms, and the estimated USD/h of the live ones (as the provider reports their
 * size) plus the new one at most maxUsdPerHour. Not atomic with the create: two
 * concurrent creates can both pass; the team's own VM quota still holds.
 */
export const agentBudgetAllows = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, size: SizeRequest | undefined) =>
  Effect.gen(function* () {
    const budget = caller.value.agent;
    if (budget === undefined) return;
    const upstream = yield* UpstreamClient;
    const page = yield* visitOwnedVms(caller, { limit: budget.maxVms + 1, after: null, labels: null }, (vm, owns) =>
      upstream.getVmForWrite(vm, { owns, scope }).pipe(
        Effect.map((found) => estimatedUsdPerHour(found.resources.cpu, found.resources.memory)),
        // Gone upstream: it costs nothing, though it still counts until deleted here.
        Effect.catchAll((error) => (error.status === 404 ? Effect.succeed(0) : Effect.fail(unavailable(error)))),
      ),
    ).pipe(Effect.catchTag("StoreError", (error) => Effect.fail(unavailable(error))));
    if (page.results.length >= budget.maxVms) {
      return yield* Effect.fail(
        new QuotaExceeded({ message: `This agent key already has its limit of ${budget.maxVms} VMs; delete one first`, budget: "agent_vms" }),
      );
    }
    const next = sizeOfCreate(size);
    const total = page.results.reduce((sum, usd) => sum + usd, 0) + estimatedUsdPerHour(next.vcpus, next.memoryMib);
    if (total > budget.maxUsdPerHour + 1e-9) {
      return yield* Effect.fail(
        new QuotaExceeded({
          message: `This VM would bring the agent's estimated cost to ${total.toFixed(2)} USD/h, over its ${budget.maxUsdPerHour} USD/h budget`,
          budget: "agent_usd_per_hour",
        }),
      );
    }
  });

/** Revokes every live client session of a VM (deleting each provider identity); how many were revoked. */
export const revokeVmClientSessions = (tenantId: TenantId, vmId: string) =>
  Effect.gen(function* () {
    const agents = yield* AgentStore;
    const upstream = yield* UpstreamClient;
    const sessions = yield* agents.liveClientSessions(tenantId, vmId).pipe(Effect.mapError(unavailable));
    let revoked = 0;
    for (const session of sessions) {
      yield* upstream.deleteIdentity(session.upstreamIdentityId).pipe(Effect.mapError(unavailable));
      const at = new Date(yield* Clock.currentTimeMillis);
      yield* agents.markClientSessionRevoked(tenantId, session.id, at).pipe(Effect.mapError(unavailable));
      revoked += 1;
    }
    return revoked;
  });
