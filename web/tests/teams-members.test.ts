import { describe, expect, test } from "bun:test";
import { requireTeamAccess, type TeamAccess } from "../services/teams/access";
import { createTeamForUser, deleteTeam, grantTeamAdmin } from "../services/teams/admin";
import { TeamApiError } from "../services/teams/errors";
import { changeMemberRole, removeMember } from "../services/teams/members";
import {
  ADMIN_GRANTS,
  ADMIN_ID,
  FakeStack,
  MEMBER_ID,
  MemoryInviteStore,
  MemoryTeamSeatSync,
  noLock,
  OUTSIDER_ID,
  standardTeam,
  TEAM_ID,
} from "./teams-fixture";

async function accessFor(stack: FakeStack, userId: string): Promise<TeamAccess> {
  const result = await requireTeamAccess({ id: userId }, TEAM_ID, { stack: stack.app() });
  if (!result.ok) throw new Error(`access refused: ${result.refusal.code}`);
  return result.access;
}

async function rejection(promise: Promise<unknown>): Promise<TeamApiError> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof TeamApiError) return error;
    throw error;
  }
  throw new Error("expected a TeamApiError");
}

describe("last-admin guard", () => {
  test("the sole admin cannot demote themself", async () => {
    const stack = standardTeam();
    const error = await rejection(changeMemberRole(await accessFor(stack, ADMIN_ID), ADMIN_ID, "member", { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync() }));
    expect(error.code).toBe("last_admin");
    expect(error.status).toBe(409);
    expect(stack.grantsOf(TEAM_ID, ADMIN_ID).has("team_admin")).toBe(true);
  });

  test("the sole admin cannot leave", async () => {
    const stack = standardTeam();
    const error = await rejection(removeMember(await accessFor(stack, ADMIN_ID), ADMIN_ID, { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync() }));
    expect(error.code).toBe("last_admin");
    expect(stack.calls.some((call) => call.startsWith("removeUser"))).toBe(false);
  });

  test("with two admins one may demote the other, then the survivor is protected", async () => {
    const stack = standardTeam();
    const deps = { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync() };
    await changeMemberRole(await accessFor(stack, ADMIN_ID), MEMBER_ID, "admin", deps);
    expect(stack.grantsOf(TEAM_ID, MEMBER_ID).has("team_admin")).toBe(true);

    await changeMemberRole(await accessFor(stack, MEMBER_ID), ADMIN_ID, "member", deps);
    expect(stack.grantsOf(TEAM_ID, ADMIN_ID).has("team_admin")).toBe(false);

    const error = await rejection(changeMemberRole(await accessFor(stack, MEMBER_ID), MEMBER_ID, "member", deps));
    expect(error.code).toBe("last_admin");
  });

  test("the guard re-reads roles inside the lock instead of trusting the caller's snapshot", async () => {
    const stack = standardTeam();
    const deps = { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync() };
    await changeMemberRole(await accessFor(stack, ADMIN_ID), MEMBER_ID, "admin", deps);
    // Both admins load access while two admins exist...
    const first = await accessFor(stack, ADMIN_ID);
    const second = await accessFor(stack, MEMBER_ID);
    await changeMemberRole(first, ADMIN_ID, "member", deps);
    // ...so each may step down, but the second sees the fresh single admin.
    const error = await rejection(changeMemberRole(second, MEMBER_ID, "member", deps));
    expect(error.code).toBe("last_admin");
    expect(stack.grantsOf(TEAM_ID, MEMBER_ID).has("team_admin")).toBe(true);
  });
});

describe("member mutations", () => {
  test("a member may leave but may not remove someone else", async () => {
    const stack = standardTeam();
    const deps = { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync() };
    const forbidden = await rejection(removeMember(await accessFor(stack, MEMBER_ID), ADMIN_ID, deps));
    expect(forbidden.code).toBe("forbidden");
    await removeMember(await accessFor(stack, MEMBER_ID), MEMBER_ID, deps);
    expect(stack.teams.get(TEAM_ID)!.members.has(MEMBER_ID)).toBe(false);
  });

  test("an admin removes a member and gets member_not_found for a non-member", async () => {
    const stack = standardTeam();
    const deps = { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync() };
    const missing = await rejection(removeMember(await accessFor(stack, ADMIN_ID), OUTSIDER_ID, deps));
    expect(missing.code).toBe("member_not_found");
    await removeMember(await accessFor(stack, ADMIN_ID), MEMBER_ID, deps);
    expect(stack.calls).toContain(`removeUser:${TEAM_ID}:${MEMBER_ID}`);
  });

  test("a member cannot promote themself", async () => {
    const stack = standardTeam();
    const error = await rejection(changeMemberRole(await accessFor(stack, MEMBER_ID), MEMBER_ID, "admin", { stack: stack.app(), lock: noLock, seats: new MemoryTeamSeatSync() }));
    expect(error.code).toBe("forbidden");
  });
});

describe("team lifecycle", () => {
  test("creating a team grants the creator team_admin and selects it", async () => {
    const stack = new FakeStack().addUser({ id: ADMIN_ID, email: "a@example.com" });
    const team = await createTeamForUser(ADMIN_ID, "New Team", { stack: stack.app() });
    expect(team.displayName).toBe("New Team");
    expect(stack.grantsOf(team.id, ADMIN_ID).has("team_admin")).toBe(true);
    expect(stack.users.get(ADMIN_ID)!.selectedTeamId).toBe(team.id);
  });

  test("a team whose admin grant fails is deleted again", async () => {
    const stack = new FakeStack().addUser({ id: ADMIN_ID });
    stack.failGrant = true;
    await expect(createTeamForUser(ADMIN_ID, "Broken", { stack: stack.app() })).rejects.toThrow();
    expect(stack.calls.some((call) => call.startsWith("deleteTeam:"))).toBe(true);
  });

  test("grantTeamAdmin accepts a team id", async () => {
    const stack = standardTeam();
    await grantTeamAdmin(stack.app(), MEMBER_ID, TEAM_ID);
    expect(stack.grantsOf(TEAM_ID, MEMBER_ID)).toEqual(new Set([...stack.grantsOf(TEAM_ID, MEMBER_ID), ...ADMIN_GRANTS]));
    expect(stack.grantsOf(TEAM_ID, MEMBER_ID).has("team_admin")).toBe(true);
  });

  test("deleting a team with an active Team subscription is refused", async () => {
    const stack = standardTeam();
    const store = new MemoryInviteStore();
    const error = await rejection(deleteTeam(await accessFor(stack, ADMIN_ID), { store, hasActiveSubscription: async () => true }));
    expect(error.code).toBe("team_has_active_subscription");
    expect(error.status).toBe(409);
    expect(stack.teams.has(TEAM_ID)).toBe(true);

    await store.createLink({ stackTeamId: TEAM_ID, tokenHash: "b".repeat(64), createdByUserId: ADMIN_ID, expiresAt: null, maxUses: null });
    await deleteTeam(await accessFor(stack, ADMIN_ID), { store, hasActiveSubscription: async () => false });
    expect(stack.teams.has(TEAM_ID)).toBe(false);
    expect(store.links[0]!.revokedAt).not.toBeNull();
  });
});
