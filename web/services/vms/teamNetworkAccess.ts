import * as Effect from "effect/Effect";
import type { ProviderId } from "./drivers";
import { VmProviderOperationError, type VmDatabaseError } from "./errors";
import { networkSlugForTeam } from "./privateNetwork";
import { VmProviderGateway, type VmProviderGatewayShape } from "./providerGateway";
import { VmRepository, type CloudVmTunnelRow, type VmRepositoryShape } from "./repository";

/**
 * Team network membership for enrolled computers.
 *
 * A team's machines trust their private network: cmux-tui and the desktop
 * accept any peer that can send packets on it. A computer reaches a team's
 * machines only while its tunnel is attached to that team's network, so
 * detaching the tunnel is what revokes access, including terminals and
 * browsers that are already open.
 */

type TunnelOwner = Pick<CloudVmTunnelRow, "providerTunnelId" | "userId" | "revokedAt">;

export type NetworkTunnelDetachResult = {
  /** Provider tunnel ids detached from the network. */
  readonly detached: readonly string[];
  /** Selected tunnels whose detach failed. */
  readonly failed: readonly string[];
};

/**
 * Detach the network's tunnels that `select` picks. Tunnels with no row in this
 * database are never touched, because the provider account can hold tunnels
 * another environment issued. Every selected tunnel is attempted; a failed
 * detach is reported in `failed` instead of stopping the rest.
 */
export function detachNetworkTunnels(input: {
  readonly repo: Pick<Required<VmRepositoryShape>, "findTunnelsByProviderTunnelIds">;
  readonly providers: Pick<Required<VmProviderGatewayShape>, "listNetworkTunnelIds" | "detachTunnelNetwork">;
  readonly provider: ProviderId;
  readonly networkId: string;
  readonly select: (tunnel: TunnelOwner) => boolean;
}): Effect.Effect<NetworkTunnelDetachResult, VmDatabaseError | VmProviderOperationError> {
  return Effect.gen(function* () {
    const tunnelIds = yield* input.providers.listNetworkTunnelIds(input.provider, input.networkId);
    const rows = yield* input.repo.findTunnelsByProviderTunnelIds(input.provider, tunnelIds);
    const detached: string[] = [];
    const failed: string[] = [];
    for (const row of rows) {
      if (!input.select(row)) continue;
      const ok = yield* input.providers.detachTunnelNetwork(input.provider, row.providerTunnelId, input.networkId).pipe(
        Effect.as(true),
        Effect.catchAll((error) => Effect.logWarning("Cloud team tunnel detach failed", {
          networkId: input.networkId,
          tunnelId: row.providerTunnelId,
          error,
        }).pipe(Effect.as(false))),
      );
      (ok ? detached : failed).push(row.providerTunnelId);
    }
    return { detached, failed };
  });
}

/** Providers whose team networks exist. Freestyle is the only one today. */
const TEAM_NETWORK_PROVIDERS: readonly ProviderId[] = ["freestyle"];

export type TeamNetworkRevocationResult = {
  readonly detached: number;
};

/**
 * Detach one user's tunnels (or, with no `userId`, every tunnel) from the
 * team's network. Idempotent: a tunnel that is no longer attached is not
 * listed by the provider, and a team with no network has nothing to detach.
 *
 * Fails when the network lookup, tunnel listing, or any selected detach fails,
 * so a webhook caller answers with an error and the sender retries.
 */
export function revokeTeamNetworkAccess(input: {
  readonly teamId: string;
  readonly userId?: string;
}): Effect.Effect<TeamNetworkRevocationResult, VmDatabaseError | VmProviderOperationError, VmRepository | VmProviderGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const { findTunnelsByProviderTunnelIds } = repo;
    const { getNetwork, listNetworkTunnelIds, detachTunnelNetwork } = providers;
    if (!findTunnelsByProviderTunnelIds || !getNetwork || !listNetworkTunnelIds || !detachTunnelNetwork) {
      return { detached: 0 };
    }
    let detached = 0;
    for (const provider of TEAM_NETWORK_PROVIDERS) {
      if (!providers.supportsPrivateNetworking?.(provider)) continue;
      const network = yield* getNetwork(provider, networkSlugForTeam(input.teamId));
      if (!network) continue;
      const result = yield* detachNetworkTunnels({
        repo: { findTunnelsByProviderTunnelIds },
        providers: { listNetworkTunnelIds, detachTunnelNetwork },
        provider,
        networkId: network.id,
        select: (tunnel) => input.userId === undefined || tunnel.userId === input.userId,
      });
      detached += result.detached.length;
      if (result.failed.length > 0) {
        return yield* Effect.fail(new VmProviderOperationError({
          provider,
          operation: "detachTunnelNetwork",
          cause: new Error(`${result.failed.length} team tunnel detach(es) failed for network ${network.id}`),
        }));
      }
    }
    return { detached };
  });
}
