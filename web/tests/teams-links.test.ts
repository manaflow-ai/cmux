import { describe, expect, test } from "bun:test";
import { requireTeamAccess } from "../services/teams/access";
import { TeamApiError, TeamServiceUnavailableError } from "../services/teams/errors";
import {
  createTeamInviteLink,
  hashInviteLinkToken,
  isInviteLinkToken,
  listTeamInviteLinks,
  previewTeamInviteLink,
  redeemTeamInviteLink,
  revokeTeamInviteLink,
} from "../services/teams/links";
import { removeMember } from "../services/teams/members";
import {
  ADMIN_ID,
  MEMBER_ID,
  MemoryInviteStore,
  noLock,
  OUTSIDER_ID,
  standardTeam,
  TEAM_ID,
} from "./teams-fixture";

const SECOND_OUTSIDER = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

async function setup(input: { expiresInDays?: 1 | 7 | 30 | null; maxUses?: number | null } = {}) {
  const stack = standardTeam().addUser({ id: SECOND_OUTSIDER });
  const store = new MemoryInviteStore();
  const access = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
  if (!access.ok) throw new Error("access refused");
  const created = await createTeamInviteLink(
    access.access,
    { expiresInDays: input.expiresInDays ?? null, maxUses: input.maxUses ?? null },
    { store, now: () => store.now },
  );
  return { stack, store, access: access.access, ...created, deps: { store, stack: stack.app() } };
}

async function code(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof TeamApiError) return `${error.status}:${error.code}`;
    throw error;
  }
  return "ok";
}

describe("invite link creation", () => {
  test("returns a 256-bit base64url token once and stores only its hash", async () => {
    const { token, link, store } = await setup({ expiresInDays: 7, maxUses: 5 });
    expect(isInviteLinkToken(token)).toBe(true);
    expect(Buffer.from(token, "base64url")).toHaveLength(32);
    expect(store.links[0]!.tokenHash).toBe(hashInviteLinkToken(token));
    expect(JSON.stringify(store.links)).not.toContain(token);
    expect(link).toEqual({
      id: store.links[0]!.id,
      role: "member",
      createdAt: "2026-09-27T12:00:00.000Z",
      createdByUserId: ADMIN_ID,
      expiresAt: "2026-10-04T12:00:00.000Z",
      maxUses: 5,
      useCount: 0,
    });
    expect(JSON.stringify(link)).not.toContain(token);
  });

  test("two links never share a token", async () => {
    const first = await setup();
    const second = await createTeamInviteLink(first.access, { expiresInDays: null, maxUses: null }, { store: first.store });
    expect(second.token).not.toBe(first.token);
  });
});

describe("invite link redemption", () => {
  test("joins as member, counts one use, and selects the team", async () => {
    const { token, stack, store, deps } = await setup();
    expect(await previewTeamInviteLink(OUTSIDER_ID, token, deps)).toEqual({ teamDisplayName: "Acme", alreadyMember: false });
    expect(await redeemTeamInviteLink(OUTSIDER_ID, token, deps)).toEqual({ teamId: TEAM_ID });
    expect(stack.teams.get(TEAM_ID)!.members.has(OUTSIDER_ID)).toBe(true);
    expect(stack.grantsOf(TEAM_ID, OUTSIDER_ID).has("team_admin")).toBe(false);
    expect(store.links[0]!.useCount).toBe(1);
    expect(stack.users.get(OUTSIDER_ID)!.selectedTeamId).toBe(TEAM_ID);
  });

  test("redeeming twice is idempotent and consumes one use", async () => {
    const { token, store, deps } = await setup({ maxUses: 2 });
    await redeemTeamInviteLink(OUTSIDER_ID, token, deps);
    await redeemTeamInviteLink(OUTSIDER_ID, token, deps);
    expect(store.links[0]!.useCount).toBe(1);
    expect(await previewTeamInviteLink(OUTSIDER_ID, token, deps)).toEqual({ teamDisplayName: "Acme", alreadyMember: true });
  });

  test("an existing member does not consume a use", async () => {
    const { token, store, deps } = await setup({ maxUses: 1 });
    expect(await redeemTeamInviteLink(MEMBER_ID, token, deps)).toEqual({ teamId: TEAM_ID });
    expect(store.links[0]!.useCount).toBe(0);
  });

  test("a full link refuses new users but still resolves for members", async () => {
    const { token, deps } = await setup({ maxUses: 1 });
    await redeemTeamInviteLink(OUTSIDER_ID, token, deps);
    expect(await code(redeemTeamInviteLink(SECOND_OUTSIDER, token, deps))).toBe("410:link_invalid");
    expect(await code(previewTeamInviteLink(SECOND_OUTSIDER, token, deps))).toBe("410:link_invalid");
    expect(await previewTeamInviteLink(OUTSIDER_ID, token, deps)).toEqual({ teamDisplayName: "Acme", alreadyMember: true });
  });

  test("an expired link is invalid", async () => {
    const { token, store, deps } = await setup({ expiresInDays: 1 });
    store.now = new Date("2026-09-28T12:00:00.001Z");
    expect(await code(previewTeamInviteLink(OUTSIDER_ID, token, deps))).toBe("410:link_invalid");
    expect(await code(redeemTeamInviteLink(OUTSIDER_ID, token, deps))).toBe("410:link_invalid");
  });

  test("a revoked link is invalid, keeps its row, and revoking again succeeds", async () => {
    const { token, link, store, access, deps } = await setup();
    await revokeTeamInviteLink(access, link.id, deps);
    expect(store.links).toHaveLength(1);
    expect(store.links[0]!.revokedAt).not.toBeNull();
    expect(await code(redeemTeamInviteLink(OUTSIDER_ID, token, deps))).toBe("410:link_invalid");
    expect(await listTeamInviteLinks(access, deps)).toEqual([]);
    await revokeTeamInviteLink(access, link.id, deps);
    expect(await code(revokeTeamInviteLink(access, "44444444-4444-4444-8444-999999999999", deps))).toBe("404:link_not_found");
  });

  test("a failed Stack add releases the claim so no use is burned", async () => {
    const { token, stack, store, deps } = await setup({ maxUses: 1 });
    stack.failAddUser = new Error("stack down");
    await expect(redeemTeamInviteLink(OUTSIDER_ID, token, deps)).rejects.toBeInstanceOf(TeamServiceUnavailableError);
    expect(store.links[0]!.useCount).toBe(0);
    expect(store.redemptions.size).toBe(0);
    expect(store.events).toEqual([`claim:${OUTSIDER_ID}`, `release:${OUTSIDER_ID}`]);
    // The released slot is usable by the next user.
    stack.failAddUser = null;
    expect(await redeemTeamInviteLink(SECOND_OUTSIDER, token, deps)).toEqual({ teamId: TEAM_ID });
    expect(store.links[0]!.useCount).toBe(1);
  });

  test("malformed and unknown tokens are invalid without touching Stack", async () => {
    const { deps, stack } = await setup();
    const before = stack.calls.length;
    expect(await code(previewTeamInviteLink(OUTSIDER_ID, "short", deps))).toBe("410:link_invalid");
    expect(await code(redeemTeamInviteLink(OUTSIDER_ID, "A".repeat(43), deps))).toBe("410:link_invalid");
    expect(stack.calls.length).toBe(before);
  });

  test("a link of a deleted team is invalid", async () => {
    const { token, deps, stack } = await setup();
    stack.teams.delete(TEAM_ID);
    expect(await code(redeemTeamInviteLink(OUTSIDER_ID, token, deps))).toBe("410:link_invalid");
  });

  test("an already-exists error from Stack counts as joined", async () => {
    const { token, stack, store, deps } = await setup();
    stack.failAddUser = Object.assign(new Error("exists"), { errorCode: "TEAM_MEMBERSHIP_ALREADY_EXISTS" });
    expect(await redeemTeamInviteLink(OUTSIDER_ID, token, deps)).toEqual({ teamId: TEAM_ID });
    expect(store.links[0]!.useCount).toBe(1);
  });
});

// Regression: a redemption row outlived the membership, so a removed member
// reopened a used single-use link and was added again without a new use.
describe("rejoining after leaving or removal", () => {
  async function accessOf(stack: ReturnType<typeof standardTeam>, userId: string) {
    const result = await requireTeamAccess({ id: userId }, TEAM_ID, { stack: stack.app() });
    if (!result.ok) throw new Error("access refused");
    return result.access;
  }

  test("a removed member cannot rejoin through a single-use link they already used", async () => {
    const { stack, store, token, deps } = await setup({ maxUses: 1 });
    await redeemTeamInviteLink(OUTSIDER_ID, token, deps);
    await removeMember(await accessOf(stack, ADMIN_ID), OUTSIDER_ID, { stack: stack.app(), lock: noLock, store });
    expect(await code(redeemTeamInviteLink(OUTSIDER_ID, token, deps))).toBe("410:link_invalid");
    expect(stack.teams.get(TEAM_ID)!.members.has(OUTSIDER_ID)).toBe(false);
  });

  test("leaving and rejoining through an unlimited link counts a new use", async () => {
    const { stack, store, token, deps } = await setup();
    await redeemTeamInviteLink(OUTSIDER_ID, token, deps);
    await removeMember(await accessOf(stack, OUTSIDER_ID), OUTSIDER_ID, { stack: stack.app(), lock: noLock, store });
    expect(await code(redeemTeamInviteLink(OUTSIDER_ID, token, deps))).toBe("ok");
    expect(store.links[0]!.useCount).toBe(2);
  });
});
