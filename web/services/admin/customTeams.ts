// Admin team setup for custom plans: create a team owned by a user, then add
// or remove its members. The custom deal itself is
// `setTeamVmEntitlementOverride` in proGrants.ts; paid access is the Team
// grant (`setTeamManualPlanGrant`).

import { createTeamForUser } from "../teams/admin";
import { TEAM_ADMIN_PERMISSION } from "../teams/permissions";
import { defaultTeamSeatSync, type TeamSeatSync } from "../teams/seatSync";
import {
  defaultTeamStackApp,
  isTeamMembershipAlreadyExists,
  withStackDeadline,
  type StackTeam,
  type TeamStackApp,
} from "../teams/stack";
import { getStackServerApp } from "../../app/lib/stack";

export const ADMIN_TEAM_NAME_MAX_LENGTH = 64;

export type AdminTeamMember = {
  readonly id: string;
  readonly primaryEmail: string | null;
  readonly displayName: string | null;
  readonly isAdmin: boolean;
};

export class AdminCustomTeamError extends Error {
  constructor(
    readonly code: "team_not_found" | "user_not_found" | "user_ambiguous" | "member_not_found" | "last_admin",
    readonly status: number,
  ) {
    super(code);
    this.name = "AdminCustomTeamError";
  }
}

type UserLookup = (emailOrId: string) => Promise<{ readonly id: string } | null>;

export type AdminCustomTeamDependencies = {
  readonly stack?: TeamStackApp;
  readonly seats?: TeamSeatSync;
  readonly findUser?: UserLookup;
};

/** Create a team owned (and administered) by `ownerUserId`; it becomes their selected team. */
export async function adminCreateTeam(
  input: { readonly owner: string; readonly displayName: string },
  dependencies: AdminCustomTeamDependencies = {},
): Promise<{ readonly id: string; readonly displayName: string }> {
  const owner = await resolveUser(input.owner, dependencies);
  return await createTeamForUser(owner.id, input.displayName, { stack: dependencies.stack });
}

export async function listAdminTeamMembers(
  teamId: string,
  dependencies: AdminCustomTeamDependencies = {},
): Promise<readonly AdminTeamMember[]> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const team = await requireTeam(stack, teamId);
  const [members, permissions] = await Promise.all([
    withStackDeadline(() => team.listUsers()),
    withStackDeadline(() => stack.listTeamMemberPermissions(teamId)),
  ]);
  const admins = adminIds(permissions);
  return members.map((member) => ({
    id: member.id,
    primaryEmail: member.primaryEmail ?? null,
    displayName: member.teamProfile?.displayName ?? member.displayName ?? null,
    isAdmin: admins.has(member.id),
  }));
}

/** Add a user (by email or id) to a team; already a member is success. */
export async function adminAddTeamMember(
  input: { readonly teamId: string; readonly user: string },
  dependencies: AdminCustomTeamDependencies = {},
): Promise<{ readonly userId: string }> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const team = await requireTeam(stack, input.teamId);
  const user = await resolveUser(input.user, dependencies);
  await withStackDeadline(async () => {
    try {
      await team.addUser(user.id);
    } catch (error) {
      if (!isTeamMembershipAlreadyExists(error)) throw error;
    }
  });
  await (dependencies.seats ?? defaultTeamSeatSync).membershipChanged(team.id);
  return { userId: user.id };
}

/** Remove a member. The team's last admin stays, so the team remains manageable. */
export async function adminRemoveTeamMember(
  input: { readonly teamId: string; readonly user: string },
  dependencies: AdminCustomTeamDependencies = {},
): Promise<{ readonly userId: string }> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const team = await requireTeam(stack, input.teamId);
  const user = await resolveUser(input.user, dependencies);
  const [members, permissions] = await Promise.all([
    withStackDeadline(() => team.listUsers()),
    withStackDeadline(() => stack.listTeamMemberPermissions(team.id)),
  ]);
  if (!members.some((member) => member.id === user.id)) throw new AdminCustomTeamError("member_not_found", 404);
  const admins = adminIds(permissions);
  if (admins.has(user.id) && admins.size === 1) throw new AdminCustomTeamError("last_admin", 409);
  await withStackDeadline(() => team.removeUser(user.id));
  await (dependencies.seats ?? defaultTeamSeatSync).membershipChanged(team.id);
  return { userId: user.id };
}

async function requireTeam(stack: TeamStackApp, teamId: string): Promise<StackTeam> {
  const team = await withStackDeadline(() => stack.getTeam(teamId));
  if (!team || team.id !== teamId) throw new AdminCustomTeamError("team_not_found", 404);
  return team;
}

function adminIds(permissions: readonly { readonly userId: string; readonly permissionId: string }[]): Set<string> {
  return new Set(permissions.filter((row) => row.permissionId === TEAM_ADMIN_PERMISSION).map((row) => row.userId));
}

async function resolveUser(emailOrId: string, dependencies: AdminCustomTeamDependencies): Promise<{ readonly id: string }> {
  const user = await (dependencies.findUser ?? defaultFindUser(dependencies.stack ?? defaultTeamStackApp()))(emailOrId.trim());
  if (!user) throw new AdminCustomTeamError("user_not_found", 404);
  return user;
}

/** An email matches exactly one Stack user's primary email; anything else is a user id. */
function defaultFindUser(stack: TeamStackApp): UserLookup {
  return async (emailOrId) => {
    if (!emailOrId.includes("@")) {
      const user = await withStackDeadline(() => stack.getUser(emailOrId));
      return user ? { id: user.id } : null;
    }
    // Exact address, not the billing matcher's canonical form: two people can
    // share a canonical Gmail address and the admin named one of them.
    const wanted = emailOrId.toLowerCase();
    const candidates = await withStackDeadline(() => getStackServerApp().listUsers({ query: emailOrId, limit: 25 }));
    const matches = candidates.filter((candidate) =>
      candidate.primaryEmail?.trim().toLowerCase() === wanted);
    if (matches.length > 1) throw new AdminCustomTeamError("user_ambiguous", 409);
    return matches[0] ? { id: matches[0].id } : null;
  };
}
