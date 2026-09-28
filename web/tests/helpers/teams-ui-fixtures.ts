import type { TeamDetail } from "../../app/[locale]/dashboard/teams/team-api";

export function teamDetailFixture(overrides: Partial<TeamDetail> = {}): TeamDetail {
  return {
    team: { id: "team-1", displayName: "Acme", profileImageUrl: null },
    viewer: {
      userId: "user-1",
      role: "admin",
      permissions: {
        updateTeam: true,
        deleteTeam: true,
        inviteMembers: true,
        readMembers: true,
        removeMembers: true,
        manageApiKeys: true,
        manageBilling: true,
      },
    },
    members: [
      { userId: "user-1", displayName: "Ada", email: "ada@x.com", profileImageUrl: null, role: "admin", isViewer: true },
      { userId: "user-2", displayName: "Bob", email: "bob@x.com", profileImageUrl: null, role: "member", isViewer: false },
    ],
    invitations: [
      { id: "inv-1", email: "cy@x.com", role: "member", expiresAt: "2026-10-01T00:00:00.000Z" },
      { id: "inv-2", email: "di@x.com", role: "admin", expiresAt: "2026-10-02T00:00:00.000Z" },
    ],
    links: [
      {
        id: "link-1",
        role: "member",
        createdAt: "2026-09-01T00:00:00.000Z",
        createdByUserId: "user-1",
        expiresAt: null,
        maxUses: 5,
        useCount: 2,
      },
    ],
    billing: { planId: "team", seats: 3, memberCount: 2, hasActiveSubscription: true },
    ...overrides,
  };
}
