import { describe, expect, test } from "bun:test";
import { AdminTeamNotFoundError } from "../services/admin/proGrants";
import {
  changeTeamMemberRoleAsOperator,
  listTeamMembersAsOperator,
  removeTeamMemberAsOperator,
  renameTeamAsOperator,
} from "../services/admin/teamMembers";
import { TeamApiError } from "../services/teams/errors";
import {
  ADMIN_ID,
  MEMBER_ID,
  MemoryInviteStore,
  MemoryTeamSeatSync,
  noLock,
  OTHER_TEAM_ID,
  OUTSIDER_ID,
  standardTeam,
  TEAM_ID,
} from "./teams-fixture";

// A cmux operator (cmux-admin) manages a customer team it is not a member of:
// it sees the roster, promotes and demotes, and removes people, under the same
// guards as a team admin (the team keeps one admin).

const OPERATOR_ID = "99999999-9999-4999-8999-999999999999";
const admin = { id: OPERATOR_ID };

async function rejection(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("expected a rejection");
}

describe("operator team members", () => {
  test("lists members admins first, with pending invitations, without the operator", async () => {
    const stack = standardTeam();
    const store = new MemoryInviteStore();
    const roster = await listTeamMembersAsOperator({ teamId: TEAM_ID, admin, stack: stack.app(), invitations: { store } });
    expect(roster.teamId).toBe(TEAM_ID);
    expect(roster.members.map((member) => [member.userId, member.role, member.isViewer])).toEqual([
      [ADMIN_ID, "admin", false],
      [MEMBER_ID, "member", false],
    ]);
    expect(roster.invitations).toEqual([]);
  });

  test("promotes a member to admin, then demotes them back", async () => {
    const stack = standardTeam();
    const dependencies = { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync() };
    const promoted = await changeTeamMemberRoleAsOperator({ teamId: TEAM_ID, userId: MEMBER_ID, role: "admin", admin, dependencies });
    expect(promoted.role).toBe("admin");
    expect(stack.grantsOf(TEAM_ID, MEMBER_ID).has("team_admin")).toBe(true);

    const demoted = await changeTeamMemberRoleAsOperator({ teamId: TEAM_ID, userId: MEMBER_ID, role: "member", admin, dependencies });
    expect(demoted.role).toBe("member");
    expect(stack.grantsOf(TEAM_ID, MEMBER_ID).has("team_admin")).toBe(false);
  });

  test("refuses to demote or remove the last admin", async () => {
    const stack = standardTeam();
    const dependencies = { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync(), store: new MemoryInviteStore() };
    const demote = await rejection(changeTeamMemberRoleAsOperator({ teamId: TEAM_ID, userId: ADMIN_ID, role: "member", admin, dependencies }));
    expect(demote).toBeInstanceOf(TeamApiError);
    expect((demote as TeamApiError).code).toBe("last_admin");
    const remove = await rejection(removeTeamMemberAsOperator({ teamId: TEAM_ID, userId: ADMIN_ID, admin, dependencies }));
    expect((remove as TeamApiError).code).toBe("last_admin");
    expect(stack.teams.get(TEAM_ID)!.members.has(ADMIN_ID)).toBe(true);
  });

  test("an operator who is also the team's only admin cannot remove or demote themselves", async () => {
    const stack = standardTeam().addMember(TEAM_ID, OPERATOR_ID, ["team_member", "$read_members"]);
    const dependencies = { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync(), store: new MemoryInviteStore() };
    // Make the operator the sole admin: demote the original admin first.
    await changeTeamMemberRoleAsOperator({ teamId: TEAM_ID, userId: OPERATOR_ID, role: "admin", admin, dependencies });
    await changeTeamMemberRoleAsOperator({ teamId: TEAM_ID, userId: ADMIN_ID, role: "member", admin, dependencies });
    const remove = await rejection(removeTeamMemberAsOperator({ teamId: TEAM_ID, userId: OPERATOR_ID, admin, dependencies }));
    expect((remove as TeamApiError).code).toBe("last_admin");
    const demote = await rejection(changeTeamMemberRoleAsOperator({ teamId: TEAM_ID, userId: OPERATOR_ID, role: "member", admin, dependencies }));
    expect((demote as TeamApiError).code).toBe("last_admin");
  });

  test("removes a member and syncs seats", async () => {
    const stack = standardTeam();
    const seats = new MemoryTeamSeatSync();
    await removeTeamMemberAsOperator({
      teamId: TEAM_ID,
      userId: MEMBER_ID,
      admin,
      dependencies: { stack: stack.app(), lock: noLock, seats, store: new MemoryInviteStore() },
    });
    expect(stack.teams.get(TEAM_ID)!.members.has(MEMBER_ID)).toBe(false);
  });

  test("a non-member target is member_not_found and a missing team is not found", async () => {
    const stack = standardTeam();
    const dependencies = { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync(), store: new MemoryInviteStore() };
    const outsider = await rejection(removeTeamMemberAsOperator({ teamId: TEAM_ID, userId: OUTSIDER_ID, admin, dependencies }));
    expect((outsider as TeamApiError).code).toBe("member_not_found");
    const missing = await rejection(listTeamMembersAsOperator({ teamId: OTHER_TEAM_ID, admin, stack: stack.app() }));
    expect(missing).toBeInstanceOf(AdminTeamNotFoundError);
  });

  test("renames the team", async () => {
    const stack = standardTeam();
    const team = await renameTeamAsOperator({ teamId: TEAM_ID, displayName: "Tecorien", admin, stack: stack.app() });
    expect(team).toEqual({ id: TEAM_ID, displayName: "Tecorien" });
    expect(stack.teams.get(TEAM_ID)!.displayName).toBe("Tecorien");
    const missing = await rejection(renameTeamAsOperator({ teamId: OTHER_TEAM_ID, displayName: "X", admin, stack: stack.app() }));
    expect(missing).toBeInstanceOf(AdminTeamNotFoundError);
  });
});
