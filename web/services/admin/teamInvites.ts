// Operator invites for a customer team. A team's own admins invite from cmux;
// this lets a cmux admin (cmux-admin) invite people into a customer team it
// set up, as admins or members, through the same invitation store, email and
// accept flow. The operator is not a member, so the email names cmux.

import { AdminTeamNotFoundError } from "./proGrants";
import {
  inviteTeamMembers,
  type InvitationDependencies,
  type InviteUrlBuilder,
} from "../teams/invitations";
import type { TeamAccess } from "../teams/access";
import { grantsByUser, TEAM_ADMIN_PERMISSION, viewerPermissionsFromGrants } from "../teams/permissions";
import { defaultTeamStackApp, withStackDeadline, type TeamStackApp } from "../teams/stack";
import type { TeamRole } from "../teams/types";

/** The sender line of an operator invite email. */
export const OPERATOR_INVITER_NAME = "cmux";

export async function inviteTeamMembersAsOperator(input: {
  readonly teamId: string;
  readonly emails: readonly string[];
  readonly role: TeamRole;
  readonly admin: { readonly id: string };
  readonly acceptUrl: InviteUrlBuilder;
  readonly stack?: TeamStackApp;
  readonly dependencies?: InvitationDependencies;
}): ReturnType<typeof inviteTeamMembers> {
  const stack = input.stack ?? defaultTeamStackApp();
  const team = await withStackDeadline(() => stack.getTeam(input.teamId));
  if (!team || team.id !== input.teamId) throw new AdminTeamNotFoundError(input.teamId);
  const [members, rows] = await Promise.all([
    withStackDeadline(() => team.listUsers()),
    withStackDeadline(() => stack.listTeamMemberPermissions(input.teamId, { recursive: true })),
  ]);
  // The operator acts with admin rights on a team it is not a member of; the
  // invitation records the operator as the inviter.
  const operatorGrants = new Set([TEAM_ADMIN_PERMISSION]);
  const access: TeamAccess = {
    userId: input.admin.id,
    team,
    members,
    grants: grantsByUser(rows),
    role: "admin",
    permissions: viewerPermissionsFromGrants(operatorGrants),
  };
  return await inviteTeamMembers(
    access,
    { emails: input.emails, role: input.role, acceptUrl: input.acceptUrl, inviterName: OPERATOR_INVITER_NAME },
    input.dependencies,
  );
}
