import { deleteIdentitySnapshot } from "../auth/identitySnapshot";
import { revokeRouteTokensForTeam, revokeRouteTokensForTeamMember } from "../coderouter/repository";
import { invalidateNativeAuthCacheForUser } from "./auth";
import { revokeTeamNetworkAccess, type TeamNetworkRevocationResult } from "./teamNetworkAccess";
import { runVmWorkflow } from "./workflows";

/**
 * What removing someone from a team revokes, in one place.
 *
 * - Their tunnels leave the team's private network. Team machines trust that
 *   network, so this cuts open terminals, browsers, and desktop sessions, not
 *   only new ones.
 * - Their identity snapshot is deleted, so every snapshot-backed check asks
 *   Stack again instead of reusing a team list up to ten minutes old.
 * - This instance's native verification cache drops their entries.
 * - Their CodeRouter CLI sessions for the team end (revoked_at), instead of
 *   living out their 30-day lifetime.
 *
 * Endpoint lease rows are not touched: on Freestyle their tokens are ledger
 * entries only (the network is the credential), and the provider's lease
 * revocation is per machine, which would also cut the team's other members.
 * Team publications are team resources and outlive any one member.
 */
export type TeamRevocationDependencies = {
  readonly revokeNetworkAccess: (input: { readonly teamId: string; readonly userId?: string }) => Promise<TeamNetworkRevocationResult>;
  readonly deleteIdentitySnapshot: (userId: string) => Promise<void>;
  readonly invalidateAuthCache: (userId: string) => void;
  readonly revokeCoderouterSessions: (input: { readonly teamId: string; readonly userId?: string }) => Promise<void>;
};

const defaultDependencies: TeamRevocationDependencies = {
  revokeNetworkAccess: (input) => runVmWorkflow(revokeTeamNetworkAccess(input)),
  deleteIdentitySnapshot: (userId) => deleteIdentitySnapshot(userId, undefined, { throwOnError: true }),
  invalidateAuthCache: invalidateNativeAuthCacheForUser,
  revokeCoderouterSessions: ({ teamId, userId }) =>
    userId === undefined ? revokeRouteTokensForTeam(teamId) : revokeRouteTokensForTeamMember({ teamId, userId }),
};

/**
 * Revoke one member's access to one team's machines. Idempotent. Both steps
 * always run; the call throws when either failed so the caller can retry.
 */
export async function revokeTeamMemberAccess(
  input: { readonly teamId: string; readonly userId: string },
  dependencies: TeamRevocationDependencies = defaultDependencies,
): Promise<TeamNetworkRevocationResult> {
  dependencies.invalidateAuthCache(input.userId);
  const [network, snapshot, sessions] = await Promise.allSettled([
    dependencies.revokeNetworkAccess({ teamId: input.teamId, userId: input.userId }),
    dependencies.deleteIdentitySnapshot(input.userId),
    dependencies.revokeCoderouterSessions({ teamId: input.teamId, userId: input.userId }),
  ]);
  if (network.status === "rejected") throw network.reason;
  if (snapshot.status === "rejected") throw snapshot.reason;
  if (sessions.status === "rejected") throw sessions.reason;
  return network.value;
}

/**
 * A deleted team: every tunnel leaves its network. Members' snapshots expire on
 * their own; with the network gone from every tunnel, a stale team id in a
 * snapshot reaches nothing.
 */
export async function revokeTeamAccess(
  input: { readonly teamId: string },
  dependencies: TeamRevocationDependencies = defaultDependencies,
): Promise<TeamNetworkRevocationResult> {
  const [network, sessions] = await Promise.allSettled([
    dependencies.revokeNetworkAccess({ teamId: input.teamId }),
    dependencies.revokeCoderouterSessions({ teamId: input.teamId }),
  ]);
  if (network.status === "rejected") throw network.reason;
  if (sessions.status === "rejected") throw sessions.reason;
  return network.value;
}
