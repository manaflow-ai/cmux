// In-memory Stack team app and invite store for tests/teams-*.test.ts. The
// services take these as dependencies, so the tests need no module mocks.
import type {
  LinkClaimResult,
  StoredInviteLink,
  TeamInviteStore,
} from "../services/teams/repository";
import type {
  StackContactChannel,
  StackSentInvitation,
  StackTeam,
  StackTeamMember,
  StackUser,
  TeamStackApp,
} from "../services/teams/stack";
import type { TeamRole } from "../services/teams/types";

export const TEAM_ID = "11111111-1111-4111-8111-111111111111";
export const OTHER_TEAM_ID = "22222222-2222-4222-8222-222222222222";
export const ADMIN_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const MEMBER_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export const OUTSIDER_ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

export const ADMIN_GRANTS = [
  "team_admin",
  "$update_team",
  "$delete_team",
  "$invite_members",
  "$read_members",
  "$remove_members",
  "$manage_api_keys",
];
export const MEMBER_GRANTS = ["team_member", "$read_members"];

type FakeUserSeed = {
  readonly id: string;
  readonly email?: string | null;
  readonly verifiedEmails?: readonly string[];
};

type FakeInvitation = { id: string; teamId: string; email: string; expiresAt: Date };

export class FakeStack {
  readonly teams = new Map<string, { displayName: string; profileImageUrl: string | null; metadata: unknown; members: Set<string> }>();
  readonly users = new Map<string, FakeUserSeed & { selectedTeamId: string | null }>();
  readonly grants = new Map<string, Set<string>>();
  invitations: FakeInvitation[] = [];
  readonly calls: string[] = [];
  failListUsers = false;
  teamGoneOnListUsers = false;
  failAddUser: unknown = null;
  failGrant = false;
  hangGetTeam = false;
  accessToken: string | null = "caller-access-token";
  private nextInvitation = 1;

  addTeam(id: string, displayName = "Acme", metadata: unknown = null): this {
    this.teams.set(id, { displayName, profileImageUrl: null, metadata, members: new Set() });
    return this;
  }

  addUser(seed: FakeUserSeed): this {
    this.users.set(seed.id, { ...seed, selectedTeamId: null });
    return this;
  }

  addMember(teamId: string, userId: string, grants: readonly string[]): this {
    if (!this.users.has(userId)) this.addUser({ id: userId, email: `${userId.slice(0, 4)}@example.com` });
    this.teams.get(teamId)!.members.add(userId);
    this.grants.set(`${teamId}:${userId}`, new Set(grants));
    return this;
  }

  grantsOf(teamId: string, userId: string): ReadonlySet<string> {
    return this.grants.get(`${teamId}:${userId}`) ?? new Set();
  }

  addInvitation(teamId: string, email: string): FakeInvitation {
    const invitation = {
      id: `00000000-0000-4000-8000-${String(this.nextInvitation++).padStart(12, "0")}`,
      teamId,
      email,
      expiresAt: new Date(Date.UTC(2026, 9, 1, 0, 0, this.nextInvitation)),
    };
    this.invitations.push(invitation);
    return invitation;
  }

  /** What Stack does when a code is used: drop the invitation, add the member. */
  consumeInvitation(invitationId: string, userId: string): void {
    const invitation = this.invitations.find((candidate) => candidate.id === invitationId);
    if (!invitation) throw new Error("no such invitation");
    this.invitations = this.invitations.filter((candidate) => candidate.id !== invitationId);
    this.teams.get(invitation.teamId)!.members.add(userId);
    this.grants.set(`${invitation.teamId}:${userId}`, new Set(MEMBER_GRANTS));
  }

  team(teamId: string): StackTeam | null {
    const data = this.teams.get(teamId);
    if (!data) return null;
    return {
      id: teamId,
      displayName: data.displayName,
      profileImageUrl: data.profileImageUrl,
      clientReadOnlyMetadata: data.metadata,
      listUsers: async (): Promise<StackTeamMember[]> => {
        this.calls.push(`listUsers:${teamId}`);
        if (this.failListUsers) throw new Error("stack down");
        // Stack's known error when the team was deleted after getTeam resolved.
        if (this.teamGoneOnListUsers) throw Object.assign(new Error(`Team ${teamId} not found.`), { errorCode: "TEAM_NOT_FOUND" });
        return [...data.members].map((id) => ({
          id,
          displayName: null,
          primaryEmail: this.users.get(id)?.email ?? null,
          profileImageUrl: null,
          teamProfile: { displayName: `Name ${id.slice(0, 4)}`, profileImageUrl: null },
        }));
      },
      addUser: async (userId) => {
        this.calls.push(`addUser:${teamId}:${userId}`);
        if (this.failAddUser) throw this.failAddUser;
        data.members.add(userId);
        this.grants.set(`${teamId}:${userId}`, new Set(MEMBER_GRANTS));
      },
      removeUser: async (userId) => {
        this.calls.push(`removeUser:${teamId}:${userId}`);
        data.members.delete(userId);
        this.grants.delete(`${teamId}:${userId}`);
      },
      inviteUser: async ({ email, callbackUrl }) => {
        this.calls.push(`inviteUser:${teamId}:${email}:${callbackUrl}`);
        this.addInvitation(teamId, email);
      },
      listInvitations: async (): Promise<StackSentInvitation[]> => {
        return this.invitations.filter((invitation) => invitation.teamId === teamId).map((invitation) => ({
          id: invitation.id,
          recipientEmail: invitation.email,
          expiresAt: invitation.expiresAt,
          revoke: async () => {
            this.calls.push(`revoke:${invitation.id}`);
            this.invitations = this.invitations.filter((candidate) => candidate.id !== invitation.id);
          },
        }));
      },
      update: async (update) => {
        this.calls.push(`updateTeam:${teamId}:${JSON.stringify(update)}`);
        if (update.displayName !== undefined) data.displayName = update.displayName;
        if (update.profileImageUrl !== undefined) data.profileImageUrl = update.profileImageUrl;
      },
      delete: async () => {
        this.calls.push(`deleteTeam:${teamId}`);
        this.teams.delete(teamId);
      },
    };
  }

  user(userId: string): StackUser | null {
    const data = this.users.get(userId);
    if (!data) return null;
    return {
      id: userId,
      primaryEmail: data.email ?? null,
      primaryEmailVerified: false,
      grantPermission: async (scope, permissionId) => {
        this.calls.push(`grant:${scope.id}:${userId}:${permissionId}`);
        if (this.failGrant) throw new Error("grant failed");
        const key = `${scope.id}:${userId}`;
        const grants = this.grants.get(key) ?? new Set<string>();
        grants.add(permissionId);
        if (permissionId === "team_admin") for (const grant of ADMIN_GRANTS) grants.add(grant);
        this.grants.set(key, grants);
      },
      revokePermission: async (scope, permissionId) => {
        this.calls.push(`revoke-permission:${scope.id}:${userId}:${permissionId}`);
        if (permissionId === "team_admin") this.grants.set(`${scope.id}:${userId}`, new Set(MEMBER_GRANTS));
      },
      update: async (update) => {
        this.calls.push(`updateUser:${userId}:${JSON.stringify(update)}`);
        if (update.selectedTeamId !== undefined) data.selectedTeamId = update.selectedTeamId;
      },
      listContactChannels: async (): Promise<StackContactChannel[]> => {
        return (data.verifiedEmails ?? []).map((value) => ({ type: "email", value, isVerified: true }));
      },
    };
  }

  app(): TeamStackApp {
    return {
      getTeam: async (teamId) => {
        if (this.hangGetTeam) return new Promise(() => {});
        return this.team(teamId);
      },
      getUser: async (userId) => {
        return this.user(userId);
      },
      createTeam: async ({ displayName, creatorUserId }) => {
        const id = "33333333-3333-4333-8333-333333333333";
        this.addTeam(id, displayName);
        if (creatorUserId) this.teams.get(id)!.members.add(creatorUserId);
        this.calls.push(`createTeam:${displayName}:${creatorUserId}`);
        return this.team(id)!;
      },
      listTeamMemberPermissions: async (teamId) => {
        if (!this.teams.has(teamId)) throw new Error("team missing");
        const rows: { userId: string; permissionId: string }[] = [];
        for (const [key, grants] of this.grants) {
          const [grantTeamId, userId] = key.split(":");
          if (grantTeamId !== teamId) continue;
          for (const permissionId of grants) rows.push({ userId: userId!, permissionId });
        }
        return rows;
      },
      getAuthJson: async () => {
        return { accessToken: this.accessToken };
      },
    };
  }
}

/** A standard team: one admin and one member. */
export function standardTeam(): FakeStack {
  return new FakeStack()
    .addTeam(TEAM_ID)
    .addMember(TEAM_ID, ADMIN_ID, ADMIN_GRANTS)
    .addMember(TEAM_ID, MEMBER_ID, MEMBER_GRANTS)
    .addUser({ id: OUTSIDER_ID, email: "outsider@example.com" });
}

type MemoryLink = { -readonly [K in keyof StoredInviteLink]: StoredInviteLink[K] } & { tokenHash: string };

/** Mirrors the SQL contract of databaseTeamInviteStore, including claim semantics. */
export class MemoryInviteStore implements TeamInviteStore {
  readonly roles = new Map<string, { role: TeamRole; invitedByUserId: string }>();
  readonly links: MemoryLink[] = [];
  readonly redemptions = new Set<string>();
  readonly events: string[] = [];
  now = new Date("2026-09-27T12:00:00.000Z");
  private nextLink = 1;

  async upsertInviteRole(input: { stackTeamId: string; email: string; role: TeamRole; invitedByUserId: string }) {
    this.events.push(`upsert:${input.email}:${input.role}`);
    this.roles.set(`${input.stackTeamId}:${input.email}`, { role: input.role, invitedByUserId: input.invitedByUserId });
  }

  async inviteRoles(stackTeamId: string, emails: readonly string[]) {
    const roles = new Map<string, TeamRole>();
    for (const email of emails) {
      const stored = this.roles.get(`${stackTeamId}:${email}`);
      if (stored) roles.set(email, stored.role);
    }
    return roles;
  }

  async deleteInviteRole(stackTeamId: string, email: string) {
    this.events.push(`delete-role:${email}`);
    this.roles.delete(`${stackTeamId}:${email}`);
  }

  async deleteTeamInviteState(stackTeamId: string) {
    for (const key of [...this.roles.keys()]) if (key.startsWith(`${stackTeamId}:`)) this.roles.delete(key);
    for (const link of this.links) if (link.stackTeamId === stackTeamId && !link.revokedAt) link.revokedAt = this.now;
  }

  async createLink(input: { stackTeamId: string; tokenHash: string; createdByUserId: string; expiresAt: Date | null; maxUses: number | null }) {
    const link: MemoryLink = {
      id: `44444444-4444-4444-8444-${String(this.nextLink++).padStart(12, "0")}`,
      stackTeamId: input.stackTeamId,
      tokenHash: input.tokenHash,
      createdAt: this.now,
      createdByUserId: input.createdByUserId,
      expiresAt: input.expiresAt,
      revokedAt: null,
      maxUses: input.maxUses,
      useCount: 0,
    };
    this.links.push(link);
    return { ...link };
  }

  private live(link: MemoryLink): boolean {
    return !link.revokedAt && (!link.expiresAt || link.expiresAt > this.now);
  }

  async listActiveLinks(stackTeamId: string) {
    return this.links.filter((link) => link.stackTeamId === stackTeamId && this.live(link)).map((link) => ({ ...link }));
  }

  async findActiveLinkByTokenHash(tokenHash: string) {
    const link = this.links.find((candidate) => candidate.tokenHash === tokenHash && this.live(candidate));
    return link ? { ...link } : null;
  }

  async revokeLink(stackTeamId: string, linkId: string) {
    const link = this.links.find((candidate) => candidate.id === linkId && candidate.stackTeamId === stackTeamId);
    if (!link) return false;
    link.revokedAt ??= this.now;
    return true;
  }

  async claimLink(linkId: string, userId: string): Promise<LinkClaimResult> {
    const key = `${linkId}:${userId}`;
    if (this.redemptions.has(key)) return "already_redeemed";
    const link = this.links.find((candidate) => candidate.id === linkId);
    if (!link || !this.live(link) || (link.maxUses !== null && link.useCount >= link.maxUses)) return "unavailable";
    this.redemptions.add(key);
    link.useCount += 1;
    this.events.push(`claim:${userId}`);
    return "claimed";
  }

  async releaseLinkClaim(linkId: string, userId: string) {
    const key = `${linkId}:${userId}`;
    if (!this.redemptions.delete(key)) return;
    const link = this.links.find((candidate) => candidate.id === linkId)!;
    link.useCount = Math.max(link.useCount - 1, 0);
    this.events.push(`release:${userId}`);
  }
}

/** A no-op advisory lock for member mutations. */
export async function noLock<T>(_teamId: string, operation: () => Promise<T>): Promise<T> {
  return operation();
}
