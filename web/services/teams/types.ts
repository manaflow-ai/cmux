/** Wire types of the team API. See docs/team-settings-and-invites.md. */

export type TeamRole = "admin" | "member";

export type TeamViewerPermissions = {
  readonly updateTeam: boolean;
  readonly deleteTeam: boolean;
  readonly inviteMembers: boolean;
  readonly readMembers: boolean;
  readonly removeMembers: boolean;
  readonly manageApiKeys: boolean;
  readonly manageBilling: boolean;
};

export type TeamPermissionName = keyof TeamViewerPermissions;

export type TeamMember = {
  readonly userId: string;
  readonly displayName: string | null;
  readonly email: string | null;
  readonly profileImageUrl: string | null;
  readonly role: TeamRole;
  readonly isViewer: boolean;
};

export type TeamInvitation = {
  readonly id: string;
  readonly email: string | null;
  readonly role: TeamRole;
  readonly expiresAt: string;
};

export type TeamInviteLink = {
  readonly id: string;
  readonly role: "member";
  readonly createdAt: string;
  readonly createdByUserId: string;
  readonly expiresAt: string | null;
  readonly maxUses: number | null;
  readonly useCount: number;
};

export type TeamBillingSummary = {
  readonly planId: string | null;
  readonly seats: number | null;
  /** Roster cap of a personal (Pro/Max) plan, members included; null when uncapped. */
  readonly memberLimit: number | null;
  readonly memberCount: number;
  readonly hasActiveSubscription: boolean;
};

export type TeamDetail = {
  readonly team: {
    readonly id: string;
    readonly displayName: string;
    readonly profileImageUrl: string | null;
  };
  readonly viewer: {
    readonly userId: string;
    readonly role: TeamRole;
    readonly permissions: TeamViewerPermissions;
  };
  readonly members: TeamMember[];
  readonly invitations: TeamInvitation[];
  readonly links: TeamInviteLink[];
  readonly billing: TeamBillingSummary;
};
