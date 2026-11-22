import { describe, expect, test } from "bun:test";
import { backfillHexclaveMirror } from "../services/auth/hexclave/backfill";
import { syncHexclaveUser } from "../services/auth/hexclave/sync";
import { OTHER_TEAM_ID, OTHER_USER_ID, projectPermission, serverTeam, serverUser, TEAM_ID, teamPermission, USER_ID } from "./helpers/hexclave-fixtures";
import { FakeHexclave, MemoryMirror } from "./helpers/hexclave-memory";

function world() {
  const hexclave = new FakeHexclave();
  hexclave.users.set(USER_ID, serverUser());
  hexclave.users.set(OTHER_USER_ID, serverUser({ id: OTHER_USER_ID, primary_email: "other@example.com" }));
  hexclave.teams.set(TEAM_ID, serverTeam());
  hexclave.teams.set(OTHER_TEAM_ID, serverTeam({ id: OTHER_TEAM_ID, display_name: "Other" }));
  hexclave.addMember(TEAM_ID, USER_ID);
  hexclave.addMember(OTHER_TEAM_ID, OTHER_USER_ID);
  hexclave.teamPermissions.push(teamPermission());
  hexclave.projectPermissions.push(projectPermission());
  return hexclave;
}

describe("Hexclave mirror backfill", () => {
  test("dry run reads and counts everything and writes nothing", async () => {
    const hexclave = world();
    const summary = await backfillHexclaveMirror({ source: hexclave, store: null, concurrency: 2, pageSize: 1 });
    expect(summary).toEqual({ teams: 2, users: 2, memberships: 2, teamPermissions: 1, projectPermissions: 1, skippedFresher: 0, pruned: 0, dryRun: true });
  });

  test("uses list calls only: no per-user reads", async () => {
    const hexclave = world();
    await backfillHexclaveMirror({ source: hexclave, store: new MemoryMirror(), concurrency: 2, pageSize: 50 });
    expect(hexclave.calls.sort()).toEqual([
      "listAllProjectPermissions",
      "listAllTeamPermissions",
      `listTeamMembersPage:${OTHER_TEAM_ID}`,
      `listTeamMembersPage:${TEAM_ID}`,
      "listTeamsPage",
      "listUsersPage",
    ].sort());
  });

  test("an entity a webhook wrote during the run keeps the webhook's fresher state", async () => {
    const hexclave = world();
    const mirror = new MemoryMirror();
    const listUsersPage = hexclave.listUsersPage;
    hexclave.listUsersPage = async (cursor, limit) => {
      const stale = await listUsersPage(cursor, limit);
      // After the page was read, the user is renamed and leaves the team; the webhook reconciles it.
      hexclave.users.set(USER_ID, serverUser({ display_name: "fresh" }));
      hexclave.removeMember(TEAM_ID, USER_ID);
      await syncHexclaveUser(USER_ID, [], { source: hexclave, store: mirror, revokeTeamMemberAccess: async () => {}, revokeTeamAccess: async () => {}, invalidateUser: async () => {} });
      return stale;
    };
    const summary = await backfillHexclaveMirror({ source: hexclave, store: mirror, concurrency: 1, pageSize: 50 });
    expect(summary.skippedFresher).toBe(1);
    expect(mirror.users.get(USER_ID)?.display_name).toBe("fresh");
    expect(mirror.teamIdsFor(USER_ID)).toEqual([]);
    expect(mirror.users.get(OTHER_USER_ID)?.id).toBe(OTHER_USER_ID);
  });

  test("pages everything into the mirror and a rerun changes nothing", async () => {
    const hexclave = world();
    const mirror = new MemoryMirror();
    const first = await backfillHexclaveMirror({ source: hexclave, store: mirror, concurrency: 3, pageSize: 1 });
    expect(first).toMatchObject({ teams: 2, users: 2, memberships: 2, dryRun: false });
    const snapshot = () => ({
      users: [...mirror.users.keys()].sort(),
      teams: [...mirror.teams.keys()].sort(),
      memberships: [...mirror.memberships].sort(),
      teamPermissions: [...mirror.teamPermissions].sort(),
      projectPermissions: [...mirror.projectPermissions].sort(),
    });
    const before = snapshot();
    expect(before.memberships).toEqual([`${OTHER_TEAM_ID}:${OTHER_USER_ID}`, `${TEAM_ID}:${USER_ID}`].sort());
    await backfillHexclaveMirror({ source: hexclave, store: mirror, concurrency: 3, pageSize: 1 });
    expect(snapshot()).toEqual(before);
  });

  test("a rerun removes users and teams Hexclave no longer lists", async () => {
    const hexclave = world();
    const mirror = new MemoryMirror();
    await backfillHexclaveMirror({ source: hexclave, store: mirror, concurrency: 2, pageSize: 50 });
    hexclave.deleteUser(OTHER_USER_ID);
    hexclave.deleteTeam(OTHER_TEAM_ID);
    const summary = await backfillHexclaveMirror({ source: hexclave, store: mirror, concurrency: 2, pageSize: 50 });
    expect(summary.pruned).toBe(2);
    expect([...mirror.users.keys()]).toEqual([USER_ID]);
    expect([...mirror.teams.keys()]).toEqual([TEAM_ID]);
  });

  test("a Hexclave failure stops the run with an error", async () => {
    const hexclave = world();
    hexclave.failNext = new Error("hexclave down");
    await expect(backfillHexclaveMirror({ source: hexclave, store: new MemoryMirror(), concurrency: 2, pageSize: 50 })).rejects.toThrow("hexclave down");
  });
});
