// Operator member management for a customer team. A cmux admin (cmux-admin)
// is not a member of the team, but can see its roster and pending invites,
// promote or demote a member, and remove one, through the same guarded paths
// a team admin uses: the per-team admin lock, the fresh re-read inside it, the
// last-admin rule, and the seat sync after a removal.

import { AdminTeamNotFoundError } from "./proGrants";
import type { TeamAccess } from "../teams/access";
import { updateTeam } from "../teams/admin";
import { listTeamInvitations, type InvitationDependencies } from "../teams/invitations";
import {
  changeMemberRole,
  removeMember,
  toTeamMember,
  type MemberMutationDependencies,
} from "../teams/members";
import { grantsByUser } from "../teams/permissions";
import { defaultTeamStackApp, withStackDeadline, type TeamStackApp } from "../teams/stack";
import type { TeamInvitation, TeamMember, TeamRole, TeamViewerPermissions } from "../teams/types";

/** An operator acts with every team capability on a team it is not a member of. */
const OPERATOR_PERMISSIONS: TeamViewerPermissions = {
  updateTeam: true,
  deleteTeam: true,
  inviteMembers: true,
  readMembers: true,
  removeMembers: true,
  manageApiKeys: true,
  manageBilling: true,
};

/**
 * The operator's view of one team: its members and their grants, with the
 * operator as an admin outside the roster. Null when the team does not exist.
 */
export async function loadOperatorTeamAccess(
  operatorId: string,
  teamId: string,
  stack: TeamStackApp,
): Promise<TeamAccess | null> {
  const team = await withStackDeadline(() => stack.getTeam(teamId));
  if (!team || team.id !== teamId) return null;
  const [members, rows] = await Promise.all([
    withStackDeadline(() => team.listUsers()),
    withStackDeadline(() => stack.listTeamMemberPermissions(teamId, { recursive: true })),
  ]);
  const grants = grantsByUser(rows);
  // An operator outside the team must not count toward its admins. One who
  // is also a real member keeps their own grants, so the last-admin guard
  // still sees them.
  if (!members.some((member) => member.id === operatorId)) grants.delete(operatorId);
  return { userId: operatorId, team, members, grants, role: "admin", permissions: OPERATOR_PERMISSIONS };
}

export async function requireOperatorTeamAccess(
  operatorId: string,
  teamId: string,
  stack: TeamStackApp,
): Promise<TeamAccess> {
  const access = await loadOperatorTeamAccess(operatorId, teamId, stack);
  if (!access) throw new AdminTeamNotFoundError(teamId);
  return access;
}

export type OperatorTeamRoster = {
  readonly teamId: string;
  readonly displayName: string;
  readonly members: readonly TeamMember[];
  readonly invitations: readonly TeamInvitation[];
};

/** Members (admins first, then by email) and pending invitations. */
export async function listTeamMembersAsOperator(input: {
  readonly teamId: string;
  readonly admin: { readonly id: string };
  readonly stack?: TeamStackApp;
  readonly invitations?: InvitationDependencies;
}): Promise<OperatorTeamRoster> {
  const stack = input.stack ?? defaultTeamStackApp();
  const access = await requireOperatorTeamAccess(input.admin.id, input.teamId, stack);
  const members = access.members
    .map((member) => toTeamMember(access, member))
    .sort((a, b) =>
      (a.role === b.role ? 0 : a.role === "admin" ? -1 : 1) ||
      (a.email ?? a.userId).localeCompare(b.email ?? b.userId));
  const invitations = await listTeamInvitations(access, input.invitations);
  return { teamId: access.team.id, displayName: access.team.displayName, members, invitations };
}

function operatorDependencies(
  operatorId: string,
  dependencies: MemberMutationDependencies,
): MemberMutationDependencies {
  return {
    ...dependencies,
    loadAccess: (teamId, stack) => requireOperatorTeamAccess(operatorId, teamId, stack),
  };
}

/** Promote or demote a member. The team keeps at least one admin (409 last_admin). */
export async function changeTeamMemberRoleAsOperator(input: {
  readonly teamId: string;
  readonly userId: string;
  readonly role: TeamRole;
  readonly admin: { readonly id: string };
  readonly dependencies?: MemberMutationDependencies;
}): Promise<TeamMember> {
  const dependencies = input.dependencies ?? {};
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const access = await requireOperatorTeamAccess(input.admin.id, input.teamId, stack);
  return changeMemberRole(access, input.userId, input.role, operatorDependencies(input.admin.id, { ...dependencies, stack }));
}

/** Remove a member. The last admin cannot be removed (409 last_admin). */
export async function removeTeamMemberAsOperator(input: {
  readonly teamId: string;
  readonly userId: string;
  readonly admin: { readonly id: string };
  readonly dependencies?: MemberMutationDependencies;
}): Promise<void> {
  const dependencies = input.dependencies ?? {};
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const access = await requireOperatorTeamAccess(input.admin.id, input.teamId, stack);
  await removeMember(access, input.userId, operatorDependencies(input.admin.id, { ...dependencies, stack }));
}

/** Rename a customer team (1 to 120 characters, trimmed), as its admins can from cmux. */
export async function renameTeamAsOperator(input: {
  readonly teamId: string;
  readonly displayName: string;
  readonly admin: { readonly id: string };
  readonly stack?: TeamStackApp;
}): Promise<{ readonly id: string; readonly displayName: string }> {
  const stack = input.stack ?? defaultTeamStackApp();
  const access = await requireOperatorTeamAccess(input.admin.id, input.teamId, stack);
  await updateTeam(access, { displayName: input.displayName });
  return { id: access.team.id, displayName: input.displayName };
}
