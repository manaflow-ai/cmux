import { describe, expect, test } from "bun:test";
import { requireTeamAccess } from "../services/teams/access";
import { TeamApiError } from "../services/teams/errors";
import { readTeamJson } from "../services/teams/http";
import {
  inviteTeamMembers,
  listTeamInvitations,
  resendTeamInvitation,
  revokeTeamInvitation,
} from "../services/teams/invitations";
import { acceptBody, createLinkBody, inviteBody, updateTeamBody } from "../services/teams/schemas";
import { ADMIN_ID, MemoryInviteStore, standardTeam, TEAM_ID } from "./teams-fixture";

const CALLBACK = "https://cmux.com/en/dashboard/team/accept";

async function adminSetup() {
  const stack = standardTeam();
  const store = new MemoryInviteStore();
  const access = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
  if (!access.ok) throw new Error("access refused");
  return { stack, store, access: access.access };
}

function jsonRequest(body: string): Request {
  return new Request("https://cmux.test/api/teams", { method: "POST", body, headers: { "content-type": "application/json" } });
}

async function parsed<T>(schema: Parameters<typeof readTeamJson<T>>[1], body: unknown) {
  const result = await readTeamJson(jsonRequest(JSON.stringify(body)), schema);
  if (result.ok) return { ok: true as const, value: result.value };
  return { ok: false as const, status: result.response.status, body: await result.response.json() as { error: { code: string } } };
}

describe("invite request validation", () => {
  test("accepts 1 to 20 valid emails and a role", async () => {
    const ok = await parsed(inviteBody, { emails: [" A@Example.com "], role: "admin" });
    expect(ok).toEqual({ ok: true, value: { emails: ["A@Example.com"], role: "admin" } });
    for (const body of [
      { emails: [], role: "member" },
      { emails: Array.from({ length: 21 }, (_, index) => `u${index}@example.com`), role: "member" },
      { emails: ["not-an-email"], role: "member" },
      { emails: ["a@example.com"], role: "owner" },
      { emails: ["a@example.com"], role: "member", locale: "//evil.com" },
      { emails: "a@example.com", role: "member" },
    ]) {
      const result = await parsed(inviteBody, body);
      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.status).toBe(400);
        expect(result.body.error.code).toBe("invalid_request");
      }
    }
  });

  test("rejects bodies over 16 KB and non-object JSON", async () => {
    const big = await readTeamJson(jsonRequest(JSON.stringify({ code: "x".repeat(17 * 1024) })), acceptBody);
    expect(big.ok || big.response.status).toBe(413);
    const array = await readTeamJson(jsonRequest("[]"), acceptBody);
    expect(array.ok || array.response.status).toBe(400);
  });

  test("links take only the allowed expiries and a positive use cap", async () => {
    expect((await parsed(createLinkBody, { expiresInDays: 7, maxUses: null })).ok).toBe(true);
    expect((await parsed(createLinkBody, { expiresInDays: null, maxUses: 10 })).ok).toBe(true);
    expect((await parsed(createLinkBody, { expiresInDays: 2, maxUses: null })).ok).toBe(false);
    expect((await parsed(createLinkBody, { expiresInDays: 7, maxUses: 0 })).ok).toBe(false);
    expect((await parsed(createLinkBody, { expiresInDays: 7, maxUses: 1.5 })).ok).toBe(false);
    expect((await parsed(createLinkBody, { expiresInDays: 7, maxUses: null, role: "admin" })).ok).toBe(false);
  });

  test("team updates accept https or inline image URLs only", async () => {
    expect((await parsed(updateTeamBody, { profileImageUrl: "https://cdn.example.com/a.png" })).ok).toBe(true);
    expect((await parsed(updateTeamBody, { profileImageUrl: "data:image/png;base64,iVBORw0KGgo=" })).ok).toBe(true);
    expect((await parsed(updateTeamBody, { profileImageUrl: null, displayName: " New " })).ok).toBe(true);
    expect((await parsed(updateTeamBody, { profileImageUrl: "javascript:alert(1)" })).ok).toBe(false);
    expect((await parsed(updateTeamBody, { profileImageUrl: "http://example.com/a.png" })).ok).toBe(false);
    expect((await parsed(updateTeamBody, { displayName: "" })).ok).toBe(false);
  });
});

describe("email invitations", () => {
  test("stores the role before Stack sends, skips members, and reports per-email results", async () => {
    const { stack, store, access } = await adminSetup();
    const memberEmail = stack.users.get(access.members.find((member) => member.id !== ADMIN_ID)!.id)!.email!;
    const result = await inviteTeamMembers(access, {
      emails: ["New@Example.com", "new@example.com", memberEmail.toUpperCase()],
      role: "admin",
      callbackUrl: CALLBACK,
    }, { store });

    expect(result.failed).toEqual([{ email: memberEmail, code: "already_member" }]);
    expect(result.invitations).toEqual([
      expect.objectContaining({ email: "new@example.com", role: "admin" }),
    ]);
    expect(store.events).toEqual(["upsert:new@example.com:admin"]);
    expect(stack.calls.filter((call) => call.startsWith("inviteUser:"))).toEqual([
      `inviteUser:${TEAM_ID}:new@example.com:${CALLBACK}`,
    ]);
  });

  test("re-inviting overwrites the role and leaves one pending invitation", async () => {
    const { stack, store, access } = await adminSetup();
    await inviteTeamMembers(access, { emails: ["x@example.com"], role: "admin", callbackUrl: CALLBACK }, { store });
    await inviteTeamMembers(access, { emails: ["x@example.com"], role: "member", callbackUrl: CALLBACK }, { store });
    const invitations = await listTeamInvitations(access, { store });
    expect(invitations).toHaveLength(1);
    expect(invitations[0]!.role).toBe("member");
    expect(stack.invitations).toHaveLength(1);
  });

  test("a failed send is reported and does not revoke the previous invitation", async () => {
    const { stack, store, access } = await adminSetup();
    await inviteTeamMembers(access, { emails: ["y@example.com"], role: "member", callbackUrl: CALLBACK }, { store });
    (access.team as { inviteUser: typeof access.team.inviteUser }).inviteUser = async () => {
      throw new Error("stack down");
    };
    const result = await inviteTeamMembers(access, { emails: ["y@example.com"], role: "member", callbackUrl: CALLBACK }, { store });
    expect(result).toEqual({ invitations: [], failed: [{ email: "y@example.com", code: "invite_failed" }] });
    expect(stack.invitations).toHaveLength(1);
  }, 15_000);

  test("resend replaces the invitation and keeps its stored role", async () => {
    const { stack, store, access } = await adminSetup();
    const [sent] = (await inviteTeamMembers(access, { emails: ["z@example.com"], role: "admin", callbackUrl: CALLBACK }, { store })).invitations;
    const resent = await resendTeamInvitation(access, sent!.id, CALLBACK, { store });
    expect(resent.id).not.toBe(sent!.id);
    expect(resent).toEqual(expect.objectContaining({ email: "z@example.com", role: "admin" }));
    expect(stack.invitations.map((invitation) => invitation.id)).toEqual([resent.id]);
  });

  test("revoke removes the invitation and its stored role; unknown ids are not found", async () => {
    const { stack, store, access } = await adminSetup();
    const [sent] = (await inviteTeamMembers(access, { emails: ["r@example.com"], role: "admin", callbackUrl: CALLBACK }, { store })).invitations;
    await revokeTeamInvitation(access, sent!.id, { store });
    expect(stack.invitations).toHaveLength(0);
    expect(store.roles.size).toBe(0);
    const error = await revokeTeamInvitation(access, sent!.id, { store }).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(TeamApiError);
    expect((error as TeamApiError).code).toBe("invitation_not_found");
  });
});
