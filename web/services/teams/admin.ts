import { hasActiveTeamSubscriptionForTeam } from "../billing/pro";
import type { TeamAccess } from "./access";
import { TeamApiError, TeamServiceUnavailableError } from "./errors";
import { TEAM_ADMIN_PERMISSION } from "./permissions";
import { databaseTeamInviteStore, type TeamInviteStore } from "./repository";
import { defaultTeamStackApp, withStackDeadline, type StackTeam, type TeamStackApp } from "./stack";

type GrantTeamAdminApp = Pick<TeamStackApp, "getUser" | "getTeam">;

/**
 * Grant Stack `team_admin` to a user on a team. Every path that creates a
 * team must call this: Stack's creator default does not make the creator a
 * cmux admin, and a team without an admin cannot be managed.
 */
export async function grantTeamAdmin(
  stackApp: GrantTeamAdminApp,
  userId: string,
  teamOrId: string | StackTeam,
): Promise<void> {
  const [user, team] = await Promise.all([
    stackApp.getUser(userId),
    typeof teamOrId === "string" ? stackApp.getTeam(teamOrId) : Promise.resolve(teamOrId),
  ]);
  if (!user || !team) throw new Error("team admin grant target not found");
  await user.grantPermission(team, TEAM_ADMIN_PERMISSION);
}

export type CreateTeamDependencies = { readonly stack?: TeamStackApp };

/**
 * Create a team owned by `userId`, grant them admin, and select it. A team
 * whose admin grant failed is deleted again rather than left unmanageable.
 */
export async function createTeamForUser(
  userId: string,
  displayName: string,
  dependencies: CreateTeamDependencies = {},
): Promise<{ id: string; displayName: string }> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const team = await withStackDeadline(() => stack.createTeam({ displayName, creatorUserId: userId }));
  try {
    await withStackDeadline(() => grantTeamAdmin(stack, userId, team));
  } catch (error) {
    await withStackDeadline(() => team.delete()).catch(() => {
      console.error("team create rollback failed", { teamId: team.id });
    });
    throw error;
  }
  // Selection is a convenience: the team exists and is administered even if
  // this write fails, so report success rather than a misleading error.
  await withStackDeadline(async () => {
    const user = await stack.getUser(userId);
    await user?.update({ selectedTeamId: team.id });
  }).catch(() => console.error("team create selection failed", { teamId: team.id }));
  return { id: team.id, displayName: team.displayName };
}

export async function updateTeam(
  access: TeamAccess,
  update: { readonly displayName?: string; readonly profileImageUrl?: string | null },
): Promise<void> {
  if (update.displayName === undefined && update.profileImageUrl === undefined) return;
  await withStackDeadline(() => access.team.update({
    ...(update.displayName !== undefined ? { displayName: update.displayName } : {}),
    ...(update.profileImageUrl !== undefined ? { profileImageUrl: update.profileImageUrl } : {}),
  }));
}

export type DeleteTeamDependencies = {
  readonly hasActiveSubscription?: (teamId: string) => Promise<boolean>;
  readonly store?: TeamInviteStore;
};

/** Delete a team unless a Team subscription would keep billing it. */
export async function deleteTeam(access: TeamAccess, dependencies: DeleteTeamDependencies = {}): Promise<void> {
  const hasActiveSubscription = dependencies.hasActiveSubscription ?? hasActiveTeamSubscriptionForTeam;
  let active: boolean;
  try {
    active = await hasActiveSubscription(access.team.id);
  } catch {
    throw new TeamServiceUnavailableError("team subscription lookup failed");
  }
  if (active) throw new TeamApiError("team_has_active_subscription", 409);
  await withStackDeadline(() => access.team.delete());
  await (dependencies.store ?? databaseTeamInviteStore).deleteTeamInviteState(access.team.id).catch(() => {
    // Links of a deleted team cannot be redeemed: Stack refuses addUser.
    console.error("team invite state cleanup failed", { teamId: access.team.id });
  });
}
