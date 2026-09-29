import { adminCount, loadTeamAccess, memberRole, type TeamAccess } from "./access";
import { TeamApiError } from "./errors";
import { TEAM_ADMIN_PERMISSION } from "./permissions";
import { withTeamAdminLock } from "./repository";
import { defaultTeamSeatSync, type TeamSeatSync } from "./seatSync";
import { defaultTeamStackApp, withStackDeadline, type TeamStackApp } from "./stack";
import type { TeamRole } from "./types";

export type MemberMutationDependencies = {
  readonly stack?: TeamStackApp;
  readonly lock?: <T>(teamId: string, operation: () => Promise<T>) => Promise<T>;
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
  operation: (fresh: TeamAccess, stack: TeamStackApp) => Promise<T>,
): Promise<T> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const lock = dependencies.lock ?? withTeamAdminLock;
  return lock(access.team.id, async () => {
    const fresh = await loadTeamAccess(access.userId, access.team.id, stack);
    if (!fresh) throw new TeamApiError("team_not_found", 403);
    return operation(fresh, stack);
  });
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
): Promise<{ userId: string; role: TeamRole }> {
  return withFreshTeam(access, dependencies, async (fresh, stack) => {
    if (fresh.role !== "admin") throw new TeamApiError("forbidden", 403);
    if (!fresh.members.some((member) => member.id === targetUserId)) {
      throw new TeamApiError("member_not_found", 404);
    }
    const current = memberRole(fresh, targetUserId);
    if (current === role) return { userId: targetUserId, role };
    if (role === "member") assertNotLastAdmin(fresh, targetUserId);
    await withStackDeadline(async () => {
      const target = await stack.getUser(targetUserId);
      if (!target) throw new Error("team member user not found");
      if (role === "admin") await target.grantPermission(fresh.team, TEAM_ADMIN_PERMISSION);
      else await target.revokePermission(fresh.team, TEAM_ADMIN_PERMISSION);
    });
    return { userId: targetUserId, role };
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
  await withFreshTeam(access, dependencies, async (fresh) => {
    const leaving = targetUserId === fresh.userId;
    if (!leaving && (fresh.role !== "admin" || !fresh.permissions.removeMembers)) {
      throw new TeamApiError("forbidden", 403);
    }
    if (!fresh.members.some((member) => member.id === targetUserId)) {
      throw new TeamApiError("member_not_found", 404);
    }
    assertNotLastAdmin(fresh, targetUserId);
    await withStackDeadline(() => fresh.team.removeUser(targetUserId));
  });
  // Outside the admin lock: the seat fact is recorded after the membership write commits.
  await (dependencies.seats ?? defaultTeamSeatSync).membershipChanged(access.team.id);
}
