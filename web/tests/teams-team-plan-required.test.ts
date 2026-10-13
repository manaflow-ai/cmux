import { describe, expect, test } from "bun:test";
import { acceptTeamInvitationCode } from "../services/teams/accept";
import { requireTeamAccess } from "../services/teams/access";
import { createTeamForUser } from "../services/teams/admin";
import type { InvitationCodeClient } from "../services/teams/invitationCode";
import { inviteTeamMembers } from "../services/teams/invitations";
import { createTeamInviteLink, redeemTeamInviteLink } from "../services/teams/links";
import { acceptReceivedInvitation } from "../services/teams/received";
import { memberLimitForTeam } from "../services/teams/seats";
import {
  TEAM_PLAN_REQUIRED_METADATA_KEY,
  teamPlanRequiredFromMetadata,
} from "../services/billing/teamResolution";
import {
  ADMIN_ID,
  FakeStack,
  MemoryInviteMailer,
  MemoryInviteStore,
  MemoryTeamSeatSync,
  OUTSIDER_ID,
  standardTeam,
  TEAM_ID,
} from "./teams-fixture";

// A created team without the Team plan holds at most three people, members
// and pending invitations together, on every way in. Team-plan teams are
// uncapped because each member is a paid seat.

const THIRD_MEMBER = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const acceptUrl = (token: string) => `https://cmux.com/en/join/${token}`;

/** Admin + member + a third member: a full roster for a team without the Team plan. */
function fullTeam(metadata: unknown = { [TEAM_PLAN_REQUIRED_METADATA_KEY]: true }): FakeStack {
  const stack = standardTeam();
  stack.teams.get(TEAM_ID)!.metadata = metadata;
  stack.addUser({ id: THIRD_MEMBER }).addMember(TEAM_ID, THIRD_MEMBER, ["team_member"]);
  return stack;
}

async function adminAccess(stack: FakeStack) {
  const access = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
  if (!access.ok) throw new Error("access refused");
  return access.access;
}

function stackCodeClient(onAccept: () => void): InvitationCodeClient {
  return {
    async details() {
      return { ok: true, value: { teamId: TEAM_ID, teamDisplayName: "Acme" } };
    },
    async accept() {
      onAccept();
      return { ok: true, value: null };
    },
  };
}

function acceptRequest(): Request {
  return new Request("https://cmux.test/api/teams/accept", {
    method: "POST",
    headers: { authorization: "Bearer native-access", "x-stack-refresh-token": "native-refresh" },
  });
}

describe("creating a team", () => {
  test("flags the new team so it needs its own plan for Cloud machines", async () => {
    const stack = new FakeStack().addUser({ id: ADMIN_ID, email: "a@example.com" });
    const team = await createTeamForUser(ADMIN_ID, "Side project", { stack: stack.app() });
    expect(teamPlanRequiredFromMetadata(stack.teams.get(team.id)!.metadata)).toBe(true);
  });

  test("the creator joins only after the flag is written", async () => {
    const stack = new FakeStack().addUser({ id: ADMIN_ID });
    await createTeamForUser(ADMIN_ID, "Side project", { stack: stack.app() });
    const flagged = stack.calls.findIndex((call) => call.startsWith("updateTeam:") && call.includes(TEAM_PLAN_REQUIRED_METADATA_KEY));
    const joined = stack.calls.findIndex((call) => call.startsWith("addUser:"));
    expect(stack.calls.some((call) => call === `createTeam:Side project:undefined`)).toBe(true);
    expect(flagged).toBeGreaterThanOrEqual(0);
    expect(joined).toBeGreaterThan(flagged);
  });

  test("a team whose flag cannot be written is deleted again, never joined", async () => {
    const stack = new FakeStack().addUser({ id: ADMIN_ID });
    stack.failMetadataUpdate = true;
    await expect(createTeamForUser(ADMIN_ID, "Broken", { stack: stack.app() })).rejects.toThrow();
    expect(stack.calls.some((call) => call.startsWith("deleteTeam:"))).toBe(true);
    expect(stack.calls.some((call) => call.startsWith("addUser:"))).toBe(false);
    expect(stack.teams.size).toBe(0);
  });
});

describe("member cap for teams without the Team plan", () => {
  test("only the Team plan lifts the cap", () => {
    expect(memberLimitForTeam({ clientReadOnlyMetadata: null })).toBe(3);
    expect(memberLimitForTeam({ clientReadOnlyMetadata: { [TEAM_PLAN_REQUIRED_METADATA_KEY]: true } })).toBe(3);
    expect(memberLimitForTeam({ clientReadOnlyMetadata: { cmuxPlan: "pro" } })).toBe(3);
    expect(memberLimitForTeam({ clientReadOnlyMetadata: { cmuxPlan: "team", cmuxSeats: 4 } })).toBeNull();
    expect(memberLimitForTeam({ clientReadOnlyMetadata: { cmuxVmPlan: "team" } })).toBeNull();
    // An operator Pro override does not cap a paying Team subscription.
    expect(memberLimitForTeam({ clientReadOnlyMetadata: { cmuxPlan: "team", cmuxVmPlan: "pro" } })).toBeNull();
  });

  test("direct invitations stop at three, counting pending ones", async () => {
    const stack = standardTeam();
    stack.teams.get(TEAM_ID)!.metadata = { [TEAM_PLAN_REQUIRED_METADATA_KEY]: true };
    const deps = { store: new MemoryInviteStore(), mailer: new MemoryInviteMailer() };
    const access = await adminAccess(stack);
    await inviteTeamMembers(access, { emails: ["one@example.com"], role: "member", acceptUrl }, deps);
    await expect(
      inviteTeamMembers(access, { emails: ["two@example.com"], role: "member", acceptUrl }, deps),
    ).rejects.toMatchObject({ code: "seat_limit", status: 409 });
  });

  test("an invite link cannot add a fourth person", async () => {
    const stack = fullTeam();
    stack.addUser({ id: OUTSIDER_ID });
    const store = new MemoryInviteStore();
    const { token } = await createTeamInviteLink(await adminAccess(stack), { expiresInDays: null, maxUses: null }, { store, now: () => store.now });
    await expect(
      redeemTeamInviteLink(OUTSIDER_ID, token, { store, stack: stack.app(), seats: new MemoryTeamSeatSync() }),
    ).rejects.toMatchObject({ code: "seat_limit" });
    expect(stack.teams.get(TEAM_ID)!.members.has(OUTSIDER_ID)).toBe(false);
  });

  test("a received invitation cannot be accepted into a full roster", async () => {
    const stack = standardTeam();
    stack.teams.get(TEAM_ID)!.metadata = { [TEAM_PLAN_REQUIRED_METADATA_KEY]: true };
    stack.setVerifiedEmails(OUTSIDER_ID, ["outsider@example.com"]);
    const store = new MemoryInviteStore();
    const mailer = new MemoryInviteMailer();
    const { invitations } = await inviteTeamMembers(await adminAccess(stack), { emails: ["outsider@example.com"], role: "member", acceptUrl }, { store, mailer });
    stack.addUser({ id: THIRD_MEMBER }).addMember(TEAM_ID, THIRD_MEMBER, ["team_member"]);
    await expect(
      acceptReceivedInvitation(OUTSIDER_ID, invitations[0]!.id, { store, stack: stack.app(), seats: new MemoryTeamSeatSync() }),
    ).rejects.toMatchObject({ code: "seat_limit" });
  });

  test("a Stack invitation code cannot add a fourth person, and the code is not used", async () => {
    const stack = fullTeam();
    stack.setVerifiedEmails(OUTSIDER_ID, ["outsider@example.com"]);
    const invitation = stack.addInvitation(TEAM_ID, "outsider@example.com");
    let used = false;
    const codes = stackCodeClient(() => {
      used = true;
      stack.consumeInvitation(invitation.id, OUTSIDER_ID);
    });
    await expect(
      acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", { stack: stack.app(), codes, store: new MemoryInviteStore(), seats: new MemoryTeamSeatSync() }),
    ).rejects.toMatchObject({ code: "seat_limit" });
    expect(used).toBe(false);
    expect(stack.teams.get(TEAM_ID)!.members.has(OUTSIDER_ID)).toBe(false);
  });

  test("a Team-plan team takes a fourth person on every path", async () => {
    const teamPlan = { cmuxPlan: "team", cmuxSeats: 3, [TEAM_PLAN_REQUIRED_METADATA_KEY]: true };

    const invite = fullTeam(teamPlan);
    const deps = { store: new MemoryInviteStore(), mailer: new MemoryInviteMailer() };
    const sent = await inviteTeamMembers(await adminAccess(invite), { emails: ["four@example.com", "five@example.com"], role: "member", acceptUrl }, deps);
    expect(sent.invitations).toHaveLength(2);

    const link = fullTeam(teamPlan);
    const store = new MemoryInviteStore();
    const { token } = await createTeamInviteLink(await adminAccess(link), { expiresInDays: null, maxUses: null }, { store, now: () => store.now });
    expect(await redeemTeamInviteLink(OUTSIDER_ID, token, { store, stack: link.app(), seats: new MemoryTeamSeatSync() })).toEqual({ teamId: TEAM_ID });

    const code = fullTeam(teamPlan);
    code.setVerifiedEmails(OUTSIDER_ID, ["outsider@example.com"]);
    const invitation = code.addInvitation(TEAM_ID, "outsider@example.com");
    const codes = stackCodeClient(() => code.consumeInvitation(invitation.id, OUTSIDER_ID));
    const accepted = await acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", { stack: code.app(), codes, store: new MemoryInviteStore(), seats: new MemoryTeamSeatSync() });
    expect(accepted.teamId).toBe(TEAM_ID);
  });
});
