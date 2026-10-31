import { describe, expect, test } from "bun:test";

import {
  AdminCustomTeamError,
  adminAddTeamMember,
  adminCreateTeam,
  adminRemoveTeamMember,
  listAdminTeamMembers,
} from "../services/admin/customTeams";
import type { StackTeam, TeamStackApp } from "../services/teams/stack";

function fakeStack() {
  const members = new Map<string, Set<string>>();
  const admins = new Map<string, Set<string>>();
  const emails: Record<string, string> = { owner: "owner@acme.dev", alice: "alice@acme.dev", bob: "bob@acme.dev" };
  const seatChanges: string[] = [];
  const selected: Record<string, string> = {};
  const team = (id: string, displayName: string): StackTeam => ({
    id,
    displayName,
    profileImageUrl: null,
    listUsers: async () => [...(members.get(id) ?? [])].map((userId) => ({ id: userId, primaryEmail: emails[userId] ?? null })),
    addUser: async (userId) => {
      if (members.get(id)?.has(userId)) throw Object.assign(new Error("exists"), { errorCode: "TEAM_MEMBERSHIP_ALREADY_EXISTS" });
      members.get(id)?.add(userId);
    },
    removeUser: async (userId) => { members.get(id)?.delete(userId); },
    inviteUser: async () => undefined,
    listInvitations: async () => [],
    update: async () => undefined,
    delete: async () => { members.delete(id); },
  });
  const teams = new Map<string, StackTeam>();
  const stack: TeamStackApp = {
    getTeam: async (teamId) => teams.get(teamId) ?? null,
    getUser: async (userId) => (emails[userId] ? {
      id: userId,
      primaryEmail: emails[userId],
      primaryEmailVerified: true,
      grantPermission: async (scope, permissionId) => {
        if (permissionId === "team_admin") admins.get(scope.id)?.add(userId);
      },
      revokePermission: async () => undefined,
      update: async (update) => { if (update.selectedTeamId) selected[userId] = update.selectedTeamId; },
      listContactChannels: async () => [],
    } : null),
    createTeam: async ({ displayName, creatorUserId }) => {
      const id = `team-${teams.size + 1}`;
      teams.set(id, team(id, displayName));
      members.set(id, new Set(creatorUserId ? [creatorUserId] : []));
      admins.set(id, new Set());
      return teams.get(id)!;
    },
    listTeamMemberPermissions: async (teamId) =>
      [...(admins.get(teamId) ?? [])].map((userId) => ({ userId, permissionId: "team_admin" })),
    getAuthJson: async () => ({ accessToken: null }),
    listUserContactChannels: async () => [],
  };
  const findUser = async (emailOrId: string) => {
    const id = Object.keys(emails).find((key) => key === emailOrId || emails[key] === emailOrId.toLowerCase());
    return id ? { id } : null;
  };
  const deps = { stack, findUser, seats: { membershipChanged: async (teamId: string) => { seatChanges.push(teamId); } } };
  return { deps, seatChanges, selected };
}

describe("admin custom teams", () => {
  test("create a team for a user, add and remove members", async () => {
    const { deps, seatChanges, selected } = fakeStack();
    const created = await adminCreateTeam({ owner: "owner@acme.dev", displayName: "Acme" }, deps);
    expect(created).toEqual({ id: "team-1", displayName: "Acme" });
    expect(selected.owner).toBe("team-1");

    await adminAddTeamMember({ teamId: "team-1", user: "alice@acme.dev" }, deps);
    await adminAddTeamMember({ teamId: "team-1", user: "bob" }, deps);
    // Adding an existing member is success, not an error.
    await adminAddTeamMember({ teamId: "team-1", user: "bob" }, deps);
    expect(await listAdminTeamMembers("team-1", deps)).toEqual([
      { id: "owner", primaryEmail: "owner@acme.dev", displayName: null, isAdmin: true },
      { id: "alice", primaryEmail: "alice@acme.dev", displayName: null, isAdmin: false },
      { id: "bob", primaryEmail: "bob@acme.dev", displayName: null, isAdmin: false },
    ]);

    await adminRemoveTeamMember({ teamId: "team-1", user: "alice" }, deps);
    expect((await listAdminTeamMembers("team-1", deps)).map((member) => member.id)).toEqual(["owner", "bob"]);
    expect(seatChanges).toEqual(["team-1", "team-1", "team-1", "team-1"]);
  });

  test("refuses unknown users, unknown teams, non-members, and the last admin", async () => {
    const { deps } = fakeStack();
    await adminCreateTeam({ owner: "owner", displayName: "Acme" }, deps);
    const code = async (run: () => Promise<unknown>) => {
      try {
        await run();
        return "ok";
      } catch (error) {
        return error instanceof AdminCustomTeamError ? error.code : String(error);
      }
    };
    expect(await code(() => adminCreateTeam({ owner: "nobody@acme.dev", displayName: "X" }, deps))).toBe("user_not_found");
    expect(await code(() => adminAddTeamMember({ teamId: "missing", user: "bob" }, deps))).toBe("team_not_found");
    expect(await code(() => adminRemoveTeamMember({ teamId: "team-1", user: "bob" }, deps))).toBe("member_not_found");
    expect(await code(() => adminRemoveTeamMember({ teamId: "team-1", user: "owner" }, deps))).toBe("last_admin");
  });
});
