import { describe, expect, test } from "bun:test";
import { acceptTeamInvitationCode } from "../services/teams/accept";
import { requireTeamAccess, type TeamAccess } from "../services/teams/access";
import type { InvitationCodeClient } from "../services/teams/invitationCode";
import { inviteTeamMembers } from "../services/teams/invitations";
import { createTeamInviteLink, redeemTeamInviteLink } from "../services/teams/links";
import { changeMemberRole, removeMember } from "../services/teams/members";
import { noteTeamMembershipChanged } from "../services/teams/seatSync";
import {
  ADMIN_ID,
  MEMBER_ID,
  MemoryInviteMailer,
  MemoryInviteStore,
  MemoryTeamSeatQueue,
  MemoryTeamSeatSync,
  noLock,
  OUTSIDER_ID,
  standardTeam,
  TEAM_ID,
  type FakeStack,
} from "./teams-fixture";

async function accessFor(stack: FakeStack, userId: string): Promise<TeamAccess> {
  const result = await requireTeamAccess({ id: userId }, TEAM_ID, { stack: stack.app() });
  if (!result.ok) throw new Error(`access refused: ${result.refusal.code}`);
  return result.access;
}

describe("membership facts mark the seat queue", () => {
  test("accepting an email invitation marks the team", async () => {
    const stack = standardTeam();
    stack.users.set(OUTSIDER_ID, { id: OUTSIDER_ID, email: "invitee@example.com", verifiedEmails: ["invitee@example.com"], selectedTeamId: null });
    const invitation = stack.addInvitation(TEAM_ID, "invitee@example.com");
    const codes: InvitationCodeClient = {
      details: async () => ({ ok: true, value: { teamId: TEAM_ID, teamDisplayName: "Acme" } }),
      accept: async () => {
        stack.consumeInvitation(invitation.id, OUTSIDER_ID);
        return { ok: true, value: null };
      },
    };
    const seats = new MemoryTeamSeatSync();
    const request = new Request("https://cmux.test/api/teams/accept", { method: "POST", headers: { authorization: "Bearer t", "x-stack-refresh-token": "r" } });
    await acceptTeamInvitationCode(request, OUTSIDER_ID, "code", { stack: stack.app(), codes, store: new MemoryInviteStore(), seats });
    expect(seats.changed).toEqual([TEAM_ID]);
  });

  test("a rejected code marks nothing", async () => {
    const stack = standardTeam();
    const codes: InvitationCodeClient = {
      details: async () => ({ ok: true, value: { teamId: TEAM_ID, teamDisplayName: "Acme" } }),
      accept: async () => ({ ok: false, failure: "invalid" }),
    };
    const seats = new MemoryTeamSeatSync();
    const request = new Request("https://cmux.test/api/teams/accept", { method: "POST", headers: { authorization: "Bearer t", "x-stack-refresh-token": "r" } });
    await expect(acceptTeamInvitationCode(request, OUTSIDER_ID, "code", { stack: stack.app(), codes, store: new MemoryInviteStore(), seats })).rejects.toThrow();
    expect(seats.changed).toEqual([]);
  });

  test("joining through a link marks the team once; an existing member does not", async () => {
    const stack = standardTeam();
    const store = new MemoryInviteStore();
    const seats = new MemoryTeamSeatSync();
    const { token } = await createTeamInviteLink(await accessFor(stack, ADMIN_ID), { expiresInDays: null, maxUses: null }, { store });
    const deps = { store, stack: stack.app(), seats };
    await redeemTeamInviteLink(OUTSIDER_ID, token, deps);
    await redeemTeamInviteLink(OUTSIDER_ID, token, deps);
    await redeemTeamInviteLink(MEMBER_ID, token, deps);
    expect(seats.changed).toEqual([TEAM_ID]);
  });

  test("a failed link join marks nothing", async () => {
    const stack = standardTeam();
    stack.failAddUser = new Error("stack down");
    const store = new MemoryInviteStore();
    const seats = new MemoryTeamSeatSync();
    const { token } = await createTeamInviteLink(await accessFor(stack, ADMIN_ID), { expiresInDays: null, maxUses: null }, { store });
    await expect(redeemTeamInviteLink(OUTSIDER_ID, token, { store, stack: stack.app(), seats })).rejects.toThrow();
    expect(seats.changed).toEqual([]);
  });

  test("removing a member and leaving both mark the team; refusals do not", async () => {
    const stack = standardTeam().addMember(TEAM_ID, OUTSIDER_ID, ["team_member", "$read_members"]);
    const seats = new MemoryTeamSeatSync();
    const deps = { stack: stack.app(), lock: noLock, seats };
    await removeMember(await accessFor(stack, ADMIN_ID), OUTSIDER_ID, deps);
    await removeMember(await accessFor(stack, MEMBER_ID), MEMBER_ID, deps);
    await expect(removeMember(await accessFor(stack, ADMIN_ID), ADMIN_ID, deps)).rejects.toThrow();
    expect(seats.changed).toEqual([TEAM_ID, TEAM_ID]);
  });

  test("sending invitations and changing roles never mark the team", async () => {
    const stack = standardTeam();
    const seats = new MemoryTeamSeatSync();
    const access = await accessFor(stack, ADMIN_ID);
    await inviteTeamMembers(access, { emails: ["new@example.com"], role: "member", acceptUrl: (token) => `https://cmux.test/join/${token}` }, { store: new MemoryInviteStore(), mailer: new MemoryInviteMailer() });
    await changeMemberRole(access, MEMBER_ID, "admin", { stack: stack.app(), lock: noLock, seats });
    expect(seats.changed).toEqual([]);
  });
});

describe("noteTeamMembershipChanged", () => {
  test("marks dirty, then defers an inline reconcile of that team", async () => {
    const queue = new MemoryTeamSeatQueue();
    const deferred: (() => Promise<unknown>)[] = [];
    const reconciled: string[] = [];
    await noteTeamMembershipChanged(TEAM_ID, {
      queue,
      reconcile: async (teamId) => { reconciled.push(teamId); },
      defer: (task) => { deferred.push(task); },
    });
    expect(queue.rows.get(TEAM_ID)!.dirtyAt).not.toBeNull();
    expect(reconciled).toEqual([]);
    await deferred[0]!();
    expect(reconciled).toEqual([TEAM_ID]);
  });

  test("never throws when the queue is down, and skips the inline run", async () => {
    const queue = new MemoryTeamSeatQueue();
    queue.failMark = true;
    let deferred = 0;
    await noteTeamMembershipChanged(TEAM_ID, { queue, defer: () => { deferred += 1; } });
    expect(deferred).toBe(0);
  });

  test("an inline reconcile failure is absorbed", async () => {
    const queue = new MemoryTeamSeatQueue();
    let task: (() => Promise<unknown>) | null = null;
    await noteTeamMembershipChanged(TEAM_ID, {
      queue,
      reconcile: async () => { throw new Error("stripe down"); },
      defer: (deferredTask) => { task = deferredTask; },
    });
    await expect(task!()).resolves.toBeUndefined();
  });
});
