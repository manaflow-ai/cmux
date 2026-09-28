import { billingPlanIdFromMetadata, billingSeatsFromMetadata } from "../billing/teamResolution";
import { hasActiveTeamSubscriptionForTeam } from "../billing/pro";
import { memberRole, type TeamAccess } from "./access";
import { TeamServiceUnavailableError } from "./errors";
import { listTeamInvitations } from "./invitations";
import { listTeamInviteLinks } from "./links";
import type { TeamInviteStore } from "./repository";
import type { StackTeamMember } from "./stack";
import type { TeamDetail, TeamMember } from "./types";

export type TeamDetailDependencies = {
  readonly store?: TeamInviteStore;
  readonly hasActiveSubscription?: (teamId: string) => Promise<boolean>;
};

function toMember(access: TeamAccess, member: StackTeamMember): TeamMember {
  return {
    userId: member.id,
    displayName: member.teamProfile?.displayName ?? member.displayName ?? null,
    email: member.primaryEmail ?? null,
    profileImageUrl: member.teamProfile?.profileImageUrl ?? member.profileImageUrl ?? null,
    role: memberRole(access, member.id),
    isViewer: member.id === access.userId,
  };
}

/**
 * Everything the team settings pages render, from one access check. The
 * roster needs `$read_members` (or admin); invitations and links are admin
 * only and come back empty for everyone else.
 */
export async function loadTeamDetail(access: TeamAccess, dependencies: TeamDetailDependencies = {}): Promise<TeamDetail> {
  const isAdmin = access.role === "admin";
  const canSeeRoster = isAdmin || access.permissions.readMembers;
  const hasActiveSubscription = dependencies.hasActiveSubscription ?? hasActiveTeamSubscriptionForTeam;
  const options = dependencies.store ? { store: dependencies.store } : {};
  const [invitations, links, activeSubscription] = await Promise.all([
    isAdmin && access.permissions.inviteMembers ? listTeamInvitations(access, options) : Promise.resolve([]),
    isAdmin ? listTeamInviteLinks(access, options) : Promise.resolve([]),
    hasActiveSubscription(access.team.id).catch(() => {
      throw new TeamServiceUnavailableError("team subscription lookup failed");
    }),
  ]);
  const visibleMembers = canSeeRoster
    ? access.members
    : access.members.filter((member) => member.id === access.userId);
  return {
    team: {
      id: access.team.id,
      displayName: access.team.displayName,
      profileImageUrl: access.team.profileImageUrl ?? null,
    },
    viewer: { userId: access.userId, role: access.role, permissions: access.permissions },
    members: visibleMembers.map((member) => toMember(access, member)),
    invitations,
    links,
    billing: {
      planId: billingPlanIdFromMetadata(access.team.clientReadOnlyMetadata),
      seats: billingSeatsFromMetadata(access.team.clientReadOnlyMetadata),
      memberCount: access.members.length,
      hasActiveSubscription: activeSubscription,
    },
  };
}
