import { adminCount, loadTeamAccess, memberRole, type TeamAccess } from "./access";
import { TeamApiError } from "./errors";
import { TEAM_ADMIN_PERMISSION } from "./permissions";
import { databaseTeamInviteStore, type TeamInviteStore, type TeamLockDb, withTeamAdminLock } from "./repository";
import { defaultTeamSeatSync, type TeamSeatSync } from "./seatSync";
import { defaultTeamStackApp, withStackDeadline, type StackTeamMember, type TeamStackApp } from "./stack";
import type { TeamMember, TeamRole } from "./types";

export type MemberMutationDependencies = {
  readonly stack?: TeamStackApp;
  /** Runs the operation under the team's admin lock, handing it the lock's transaction when there is one. */
  readonly lock?: <T>(teamId: string, operation: (db?: TeamLockDb) => Promise<T>) => Promise<T>;
  readonly store?: TeamInviteStore;
  readonly seats?: TeamSeatSync;
};

/**
 * Re-read the team inside the per-team admin lock. The caller's access was
 * checked before the lock; roles may have changed since, so every guard runs
 * against this fresh view.
 */
async function withFreshTeam<T>(
  access: TeamAccess,
  dependencies: MemberMutationDependencies,
  operation: (fresh: TeamAccess, stack: TeamStackApp, db: TeamLockDb | undefined) => Promise<T>,
): Promise<T> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const lock = dependencies.lock ?? withTeamAdminLock;
  return lock(access.team.id, async (db) => {
    const fresh = await loadTeamAccess(access.userId, access.team.id, stack);
    if (!fresh) throw new TeamApiError("team_not_found", 403);
    return operation(fresh, stack, db);
  });
}

/**
 * The roster's member shape. Every reply that carries a member uses this, so
 * a client can decode one the same way wherever it came from.
 */
export function toTeamMember(access: TeamAccess, member: StackTeamMember, role: TeamRole = memberRole(access, member.id)): TeamMember {
  return {
    userId: member.id,
    displayName: member.teamProfile?.displayName ?? member.displayName ?? null,
    email: member.primaryEmail ?? null,
    profileImageUrl: member.teamProfile?.profileImageUrl ?? member.profileImageUrl ?? null,
    role,
    isViewer: member.id === access.userId,
  };
}

/** Throw `last_admin` when removing `userId`'s admin role would leave none. */
export function assertNotLastAdmin(access: Pick<TeamAccess, "grants" | "members">, userId: string): void {
  if (memberRole(access, userId) === "admin" && adminCount(access) <= 1) {
    throw new TeamApiError("last_admin", 409);
  }
}

/** Promote or demote a member. Admin only; the team keeps one admin. */
export async function changeMemberRole(
  access: TeamAccess,
  targetUserId: string,
  role: TeamRole,
  dependencies: MemberMutationDependencies = {},
): Promise<TeamMember> {
  return withFreshTeam(access, dependencies, async (fresh, stack) => {
    if (fresh.role !== "admin") throw new TeamApiError("forbidden", 403);
    const target = fresh.members.find((member) => member.id === targetUserId);
    if (!target) {
      throw new TeamApiError("member_not_found", 404);
    }
    const current = memberRole(fresh, targetUserId);
    // The requested role, not `memberRole(fresh, ...)`: `fresh` is a snapshot
    // taken before the grant below, so it still reports the old role.
    if (current === role) return toTeamMember(fresh, target, role);
    if (role === "member") assertNotLastAdmin(fresh, targetUserId);
    await withStackDeadline(async () => {
      const user = await stack.getUser(targetUserId);
      if (!user) throw new Error("team member user not found");
      if (role === "admin") await user.grantPermission(fresh.team, TEAM_ADMIN_PERMISSION);
      else await user.revokePermission(fresh.team, TEAM_ADMIN_PERMISSION);
    });
    return toTeamMember(fresh, target, role);
  });
}

/**
 * Remove a member, or leave when `targetUserId` is the caller. Removing
 * someone else needs admin plus Stack `$remove_members`. The last admin can
 * neither leave nor be removed; they delete the team instead.
 */
export async function removeMember(
  access: TeamAccess,
  targetUserId: string,
  dependencies: MemberMutationDependencies = {},
): Promise<void> {
  await withFreshTeam(access, dependencies, async (fresh, _stack, db) => {
    const leaving = targetUserId === fresh.userId;
    if (!leaving && (fresh.role !== "admin" || !fresh.permissions.removeMembers)) {
      throw new TeamApiError("forbidden", 403);
    }
    if (!fresh.members.some((member) => member.id === targetUserId)) {
      throw new TeamApiError("member_not_found", 404);
    }
    assertNotLastAdmin(fresh, targetUserId);
    // On the lock's transaction, before the Stack removal: if that removal
    // fails the delete rolls back and they stay a member; if it succeeds they
    // are never a former member who can reopen a link they already used.
    await (dependencies.store ?? databaseTeamInviteStore).forgetLinkRedemptions(fresh.team.id, targetUserId, db);
    await withStackDeadline(() => fresh.team.removeUser(targetUserId));
  });
  // Outside the admin lock: the seat fact is recorded after the membership write commits.
  await (dependencies.seats ?? defaultTeamSeatSync).membershipChanged(access.team.id);
}
