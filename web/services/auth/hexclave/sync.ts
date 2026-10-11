import type { HexclaveMirrorStore, HexclaveUserState } from "./mirrorStore";
import type { HexclaveSource } from "./serverApi";
import type { HexclaveWebhookEvent } from "./webhookEvents";

export type HexclaveSyncDependencies = {
  readonly source: HexclaveSource;
  readonly store: HexclaveMirrorStore;
  readonly revokeTeamMemberAccess: (input: { readonly teamId: string; readonly userId: string }) => Promise<unknown>;
  readonly revokeTeamAccess: (input: { readonly teamId: string }) => Promise<unknown>;
  /** Drop the user's identity snapshot and native auth cache. Must throw on failure. */
  readonly invalidateUser: (userId: string) => Promise<void>;
};

export type HexclaveSyncResult = {
  readonly entity: "user" | "team";
  readonly id: string;
  readonly gone: boolean;
  readonly revokedTeamIds: readonly string[];
};

/** Everything Hexclave knows about a user, read in one place. A missing user is `gone`. */
export async function readHexclaveUserState(source: HexclaveSource, userId: string): Promise<HexclaveUserState> {
  const user = await source.getUser(userId);
  if (!user) return { kind: "gone" };
  const [teams, teamPermissions, projectPermissions] = await Promise.all([
    source.listUserTeams(userId),
    source.listUserTeamPermissions(userId),
    source.listUserProjectPermissions(userId),
  ]);
  return { kind: "present", user, teams, teamPermissions, projectPermissions };
}

function assertNever(value: never): never {
  throw new Error(`Unhandled Hexclave webhook event ${JSON.stringify(value)}`);
}

/**
 * Apply one validated Hexclave event.
 *
 * An event is only a signal naming the entity that changed: the mirror is
 * rebuilt from a fresh Hexclave read, never from the payload, so a late or
 * repeated delivery cannot write stale state. Revocation follows the
 * reconciled truth: a membership is revoked when Hexclave no longer lists it,
 * and a team when Hexclave no longer has it. Any thrown error must become a
 * 5xx so Svix retries; every step is idempotent.
 */
export async function applyHexclaveWebhookEvent(
  event: HexclaveWebhookEvent,
  dependencies: HexclaveSyncDependencies,
): Promise<HexclaveSyncResult> {
  switch (event.type) {
    case "user.created":
    case "user.updated":
      return syncHexclaveUser(event.data.id, [], dependencies);
    case "user.deleted":
      // The payload's team list survives a retry after the mirror rows are gone.
      return syncHexclaveUser(event.data.id, event.data.teams.map((team) => team.id), dependencies);
    case "team_membership.deleted":
      return syncHexclaveUser(event.data.user_id, [event.data.team_id], dependencies);
    case "team_membership.created":
    case "team_permission.created":
    case "team_permission.deleted":
    case "project_permission.created":
    case "project_permission.deleted":
      return syncHexclaveUser(event.data.user_id, [], dependencies);
    case "team.created":
    case "team.updated":
    case "team.deleted":
      return syncHexclaveTeam(event.data.id, dependencies);
    default:
      return assertNever(event);
  }
}

/**
 * Reconcile one user, then carry out every pending membership revocation the
 * reconcile persisted (memberships it removed, the event's candidates, and
 * any earlier revoke that failed), then invalidate the user's cached identity.
 * A pending row is deleted only after its revoke succeeds, so a 500 and Svix
 * retry revoke again even though the mirror no longer lists the membership.
 */
export async function syncHexclaveUser(
  userId: string,
  revokeCandidateTeamIds: readonly string[],
  dependencies: HexclaveSyncDependencies,
): Promise<HexclaveSyncResult> {
  const { store } = dependencies;
  const result = await store.reconcileUser(
    userId,
    () => readHexclaveUserState(dependencies.source, userId),
    { revokeCandidateTeamIds },
  );
  const revoked: string[] = [];
  await settleAll(result.pendingRevocationTeamIds.map((teamId) => async () => {
    // A concurrent reconcile that saw the member re-added deleted the row.
    if (!await store.isRevocationPending({ teamId, userId })) return;
    await dependencies.revokeTeamMemberAccess({ teamId, userId });
    await store.clearPendingRevocation({ teamId, userId });
    revoked.push(teamId);
  }));
  await dependencies.invalidateUser(userId);
  return { entity: "user", id: userId, gone: result.state.kind === "gone", revokedTeamIds: revoked.sort() };
}

/**
 * Reconcile one team. When Hexclave no longer has it, revoke the team's
 * network and sessions. Members' cached identities carry the team (name,
 * billing fields), so they are invalidated either way.
 */
export async function syncHexclaveTeam(
  teamId: string,
  dependencies: HexclaveSyncDependencies,
): Promise<HexclaveSyncResult> {
  const result = await dependencies.store.reconcileTeam(teamId, () => dependencies.source.getTeam(teamId));
  const gone = result.team === null;
  if (gone) await dependencies.revokeTeamAccess({ teamId });
  await settleAll(result.memberIds.map((userId) => () => dependencies.invalidateUser(userId)));
  return { entity: "team", id: teamId, gone, revokedTeamIds: gone ? [teamId] : [] };
}

/** Run every task; throw the first failure only after all have settled, so one failure does not skip the rest. */
async function settleAll(tasks: readonly (() => Promise<unknown>)[]): Promise<void> {
  const results = await Promise.allSettled(tasks.map((task) => task()));
  const failure = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
  if (failure) throw failure.reason;
}
