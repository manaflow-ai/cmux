import * as Effect from "effect/Effect";
import type { ProviderId, ProviderNetworkTunnel } from "./drivers";
import type { VmProviderOperationError } from "./errors";
import { isProviderNetworkAddressExhausted } from "./providerErrors";
import { VmProviderGateway } from "./providerGateway";
import { VmRepository } from "./repository";

/**
 * Address capacity of an owner's private network.
 *
 * Every machine and every attached tunnel holds one IPv4 address, and a
 * platform-derived network has 254. Freestyle never releases a tunnel's
 * address on its own ("an idle tunnel costs nothing and never expires"), so a
 * network fills with tunnels nobody uses and then refuses every create.
 *
 * Reclaim frees only what the control plane can prove is unused:
 *
 * - A tunnel whose row here is revoked. Its owner signed out or unenrolled,
 *   and no row will ever hand its config out again, so it is deleted.
 * - A tunnel no row here describes, older than {@link FOREIGN_TUNNEL_MIN_AGE_MS}.
 *   It was issued by another deployment sharing the provider account (a
 *   dev-backend stack or staging), so it is detached from this network only,
 *   never deleted: its owner may still use it elsewhere.
 *
 * A tunnel with a live row is never touched, however old. The Mac reuses its
 * saved WireGuard config indefinitely and re-enrolls only when a machine's
 * address falls outside its routes, so enrollment time is not a use signal
 * and a deleted tunnel would leave that Mac silently disconnected.
 */

/**
 * The youngest unknown tunnel reclaim may detach. An enrollment creates the
 * provider tunnel before it inserts the row, inside a mutation lease of at
 * most three minutes; a day covers that window with a wide margin and spares
 * a tunnel another deployment enrolled today.
 */
export const FOREIGN_TUNNEL_MIN_AGE_MS = 24 * 60 * 60 * 1000;

/**
 * Reclaim actions per full-network request. One free address is enough for
 * the retried create; the rest is headroom, bounded so reclaim stays well
 * inside the create route's budget (each call is ~150 ms, four at a time).
 */
export const MAX_RECLAIM_ACTIONS = 16;
const RECLAIM_CONCURRENCY = 4;

/** Revoked tunnels the periodic reconcile deletes per run. */
export const RECONCILE_REVOKED_TUNNEL_LIMIT = 50;
const PROVIDER_TUNNEL_ID_BATCH = 500;

export type NetworkReclaimAction = {
  readonly kind: "delete" | "detach";
  readonly tunnelId: string;
  readonly reason: "revoked_row" | "foreign_tunnel";
};

type TunnelRowState = { readonly providerTunnelId: string; readonly revokedAt: Date | null };

function rowStates(rows: readonly TunnelRowState[]): Map<string, "active" | "revoked"> {
  const states = new Map<string, "active" | "revoked">();
  for (const row of rows) {
    // Any live row keeps the tunnel, whatever older revoked rows say.
    if (row.revokedAt === null) states.set(row.providerTunnelId, "active");
    else if (!states.has(row.providerTunnelId)) states.set(row.providerTunnelId, "revoked");
  }
  return states;
}

/** The reclaim actions for one full network, safest first, least recently changed first. */
export function planNetworkReclaim(input: {
  readonly tunnels: readonly ProviderNetworkTunnel[];
  readonly rows: readonly TunnelRowState[];
  readonly now: number;
  readonly limit?: number;
}): NetworkReclaimAction[] {
  const states = rowStates(input.rows);
  const lastChanged = (tunnel: ProviderNetworkTunnel) => Math.max(tunnel.createdAt, tunnel.updatedAt);
  const byAge = (a: ProviderNetworkTunnel, b: ProviderNetworkTunnel) => lastChanged(a) - lastChanged(b);
  const revoked = input.tunnels.filter((tunnel) => states.get(tunnel.id) === "revoked").sort(byAge);
  const foreign = input.tunnels
    .filter((tunnel) => !states.has(tunnel.id))
    // An unknown timestamp (0) reads as old; the floor only protects
    // tunnels the provider says are young.
    .filter((tunnel) => input.now - lastChanged(tunnel) >= FOREIGN_TUNNEL_MIN_AGE_MS)
    .sort(byAge);
  return [
    ...revoked.map((tunnel) => ({ kind: "delete" as const, tunnelId: tunnel.id, reason: "revoked_row" as const })),
    ...foreign.map((tunnel) => ({ kind: "detach" as const, tunnelId: tunnel.id, reason: "foreign_tunnel" as const })),
  ].slice(0, input.limit ?? MAX_RECLAIM_ACTIONS);
}

export type NetworkReclaimResult = { readonly planned: number; readonly freed: number; readonly failed: number };

const NOTHING_RECLAIMED: NetworkReclaimResult = { planned: 0, freed: 0, failed: 0 };

/**
 * Free addresses in `networkId` that the policy above proves unused. Never
 * fails: a reclaim that cannot run leaves the original refusal to answer.
 */
export function reclaimNetworkAddresses(input: {
  readonly provider: ProviderId;
  readonly networkId: string;
  readonly now?: number;
}): Effect.Effect<NetworkReclaimResult, never, VmRepository | VmProviderGateway> {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const repo = yield* VmRepository;
    const { listNetworkTunnels, deleteTunnel, detachTunnelNetwork } = providers;
    const findRows = repo.findTunnelsByProviderTunnelIds;
    if (!listNetworkTunnels || !deleteTunnel || !detachTunnelNetwork || !findRows) return NOTHING_RECLAIMED;
    const tunnels = yield* listNetworkTunnels(input.provider, input.networkId);
    const rows = yield* findRows(input.provider, tunnels.map((tunnel) => tunnel.id));
    const actions = planNetworkReclaim({ tunnels, rows, now: input.now ?? Date.now() });
    const outcomes = yield* Effect.forEach(actions, (action) => {
      const run = action.kind === "delete"
        ? deleteTunnel(input.provider, action.tunnelId)
        : detachTunnelNetwork(input.provider, action.tunnelId, input.networkId);
      return run.pipe(
        Effect.as(true),
        Effect.catchAll((error) => Effect.logWarning("Cloud network reclaim action failed", {
          networkId: input.networkId,
          tunnelId: action.tunnelId,
          action: action.kind,
          reason: action.reason,
          error,
        }).pipe(Effect.as(false))),
      );
    }, { concurrency: RECLAIM_CONCURRENCY });
    const freed = outcomes.filter(Boolean).length;
    const result = { planned: actions.length, freed, failed: actions.length - freed };
    yield* Effect.logInfo("Cloud network address reclaim", {
      networkId: input.networkId,
      attachedTunnels: tunnels.length,
      revokedDeleted: actions.filter((action, index) => action.kind === "delete" && outcomes[index]).length,
      foreignDetached: actions.filter((action, index) => action.kind === "detach" && outcomes[index]).length,
      ...result,
    });
    return result;
  }).pipe(
    Effect.catchAll((error) => Effect.logWarning("Cloud network reclaim skipped", { networkId: input.networkId, error }).pipe(
      Effect.as(NOTHING_RECLAIMED),
    )),
  );
}

/**
 * Run `attempt`; when the provider refuses it for a full network, reclaim and
 * run it once more. A second refusal is final and reaches the caller as it
 * came, so the route answers `vm_network_full` instead of retrying forever.
 */
export function retryAfterNetworkReclaim<A, E extends VmProviderOperationError, R>(
  input: { readonly provider: ProviderId; readonly networkId: string },
  attempt: Effect.Effect<A, E, R>,
): Effect.Effect<A, E, R | VmRepository | VmProviderGateway> {
  return attempt.pipe(
    Effect.catchIf(
      (error) => isProviderNetworkAddressExhausted(error),
      (error) => reclaimNetworkAddresses(input).pipe(
        Effect.flatMap((result) => result.freed > 0 ? attempt : Effect.fail(error)),
      ),
    ),
  );
}

/**
 * Delete provider tunnels whose row here is revoked. A revoke normally deletes
 * the provider tunnel first, so these are the leftovers of a revoke whose
 * provider call failed or of rows revoked by hand. Tunnels with a live row and
 * tunnels no row describes are left alone: the account is shared with other
 * deployments, whose tunnels only they may delete.
 */
export function reconcileRevokedProviderTunnels(input: {
  readonly provider?: ProviderId;
  readonly limit?: number;
} = {}): Effect.Effect<{ readonly checked: number; readonly deleted: number; readonly failed: number }, never, VmRepository | VmProviderGateway> {
  const provider = input.provider ?? "freestyle";
  const empty = { checked: 0, deleted: 0, failed: 0 };
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const repo = yield* VmRepository;
    const { listTunnels, deleteTunnel } = providers;
    const findRows = repo.findTunnelsByProviderTunnelIds;
    if (!listTunnels || !deleteTunnel || !findRows) return empty;
    const tunnels = yield* listTunnels(provider);
    const ids = tunnels.map((tunnel) => tunnel.id);
    const rows: TunnelRowState[] = [];
    for (let index = 0; index < ids.length; index += PROVIDER_TUNNEL_ID_BATCH) {
      rows.push(...(yield* findRows(provider, ids.slice(index, index + PROVIDER_TUNNEL_ID_BATCH))));
    }
    const states = rowStates(rows);
    const revoked = ids.filter((id) => states.get(id) === "revoked").slice(0, input.limit ?? RECONCILE_REVOKED_TUNNEL_LIMIT);
    const outcomes = yield* Effect.forEach(revoked, (tunnelId) => deleteTunnel(provider, tunnelId).pipe(
      Effect.as(true),
      Effect.catchAll((error) => Effect.logWarning("Cloud revoked tunnel cleanup failed", { tunnelId, error }).pipe(Effect.as(false))),
    ), { concurrency: 2 });
    const deleted = outcomes.filter(Boolean).length;
    const result = { checked: tunnels.length, deleted, failed: revoked.length - deleted };
    if (revoked.length > 0) yield* Effect.logInfo("Cloud revoked tunnel cleanup", result);
    return result;
  }).pipe(
    Effect.catchAll((error) => Effect.logWarning("Cloud revoked tunnel cleanup skipped", { error }).pipe(Effect.as(empty))),
  );
}
