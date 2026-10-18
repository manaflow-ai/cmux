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
import { ADMIN_ID, MemoryInviteMailer, MemoryInviteStore, standardTeam, TEAM_ID } from "./teams-fixture";

const acceptUrl = (token: string) => `https://cmux.com/en/join/${token}`;

async function adminSetup() {
  const stack = standardTeam();
  const store = new MemoryInviteStore();
  const mailer = new MemoryInviteMailer();
  const access = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
  if (!access.ok) throw new Error("access refused");
  return { stack, store, mailer, access: access.access, deps: { store, mailer } };
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
  test("writes the row, sends one email per new address, skips members, and reports per-email results", async () => {
    const { stack, mailer, access, deps } = await adminSetup();
    const memberEmail = stack.users.get(access.members.find((member) => member.id !== ADMIN_ID)!.id)!.email!;
    const result = await inviteTeamMembers(access, {
      emails: ["New@Example.com", "new@example.com", memberEmail.toUpperCase()],
      role: "admin",
      acceptUrl,
    }, deps);

    expect(result.failed).toEqual([{ email: memberEmail, code: "already_member" }]);
    expect(result.invitations).toEqual([expect.objectContaining({ email: "new@example.com", role: "admin" })]);
    expect(mailer.sent).toHaveLength(1);
    expect(mailer.sent[0]).toMatchObject({ to: "new@example.com", teamName: "Acme", role: "admin", inviterName: "Name aaaa" });
    expect(mailer.sent[0]!.acceptUrl).toMatch(/^https:\/\/cmux\.com\/en\/join\/[A-Za-z0-9_-]{43}$/);
    expect(stack.calls.filter((call) => call.startsWith("inviteUser:"))).toEqual([]);
  });

  test("re-inviting leaves one pending invitation with the new role", async () => {
    const { access, deps } = await adminSetup();
    await inviteTeamMembers(access, { emails: ["x@example.com"], role: "admin", acceptUrl }, deps);
    await inviteTeamMembers(access, { emails: ["x@example.com"], role: "member", acceptUrl }, deps);
    const invitations = await listTeamInvitations(access, deps);
    expect(invitations).toHaveLength(1);
    expect(invitations[0]!.role).toBe("member");
  });

  test("a failed send deletes its row and keeps the previous invitation", async () => {
    const { store, mailer, access, deps } = await adminSetup();
    await inviteTeamMembers(access, { emails: ["y@example.com"], role: "admin", acceptUrl }, deps);
    mailer.failFor.add("y@example.com");
    const result = await inviteTeamMembers(access, { emails: ["y@example.com"], role: "member", acceptUrl }, deps);
    expect(result).toEqual({ invitations: [], failed: [{ email: "y@example.com", code: "invite_failed" }] });
    const invitations = await listTeamInvitations(access, deps);
    expect(invitations.map((invitation) => invitation.role)).toEqual(["admin"]);
    expect(store.emailInvitations).toHaveLength(1);
  });

  test("a failed first invite leaves nothing pending", async () => {
    const { store, mailer, access, deps } = await adminSetup();
    mailer.failFor.add("v@example.com");
    await inviteTeamMembers(access, { emails: ["v@example.com"], role: "admin", acceptUrl }, deps);
    expect(store.emailInvitations).toHaveLength(0);
  });

  test("resend sends again with a fresh token and keeps the row and role; a failed resend keeps the old token", async () => {
    const { store, mailer, access, deps } = await adminSetup();
    const [sent] = (await inviteTeamMembers(access, { emails: ["z@example.com"], role: "admin", acceptUrl }, deps)).invitations;
    const before = store.emailInvitations[0]!.tokenHash;
    const resent = await resendTeamInvitation(access, sent!.id, acceptUrl, deps);
    expect(resent.id).toBe(sent!.id);
    expect(resent.role).toBe("admin");
    expect(mailer.sent).toHaveLength(2);
    expect(store.emailInvitations[0]!.tokenHash).not.toBe(before);
    const after = store.emailInvitations[0]!.tokenHash;
    mailer.failFor.add("z@example.com");
    await expect(resendTeamInvitation(access, sent!.id, acceptUrl, deps)).rejects.toThrow("mail down");
    expect(store.emailInvitations[0]!.tokenHash).toBe(after);
  });

  test("revoke hides the invitation; unknown and revoked-twice ids are not found or idempotent", async () => {
    const { access, deps } = await adminSetup();
    const [sent] = (await inviteTeamMembers(access, { emails: ["r@example.com"], role: "admin", acceptUrl }, deps)).invitations;
    await revokeTeamInvitation(access, sent!.id, deps);
    expect(await listTeamInvitations(access, deps)).toHaveLength(0);
    await revokeTeamInvitation(access, sent!.id, deps);
    const error = await revokeTeamInvitation(access, "99999999-9999-4999-8999-999999999999", deps).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(TeamApiError);
    expect((error as TeamApiError).code).toBe("invitation_not_found");
  });
});

describe("personal plan member limit", () => {
  const THIRD_MEMBER = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";

  async function proTeam(extraMembers: readonly string[] = []) {
    const stack = standardTeam();
    stack.teams.get(TEAM_ID)!.metadata = { cmuxPlan: "pro" };
    for (const id of extraMembers) stack.addUser({ id }).addMember(TEAM_ID, id, ["team_member"]);
    const store = new MemoryInviteStore();
    const mailer = new MemoryInviteMailer();
    const access = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
    if (!access.ok) throw new Error("access refused");
    return { stack, store, mailer, access: access.access, deps: { store, mailer } };
  }

  test("a Pro team of two admits one more invitation, and pending invitations hold the seat", async () => {
    const { access, deps } = await proTeam();
    const first = await inviteTeamMembers(access, { emails: ["one@example.com"], role: "member", acceptUrl }, deps);
    expect(first.invitations.map((invitation) => invitation.email)).toEqual(["one@example.com"]);
    await expect(
      inviteTeamMembers(access, { emails: ["two@example.com"], role: "member", acceptUrl }, deps),
    ).rejects.toMatchObject({ code: "seat_limit", status: 409 });
    // Re-inviting the pending email consumes no extra seat.
    const again = await inviteTeamMembers(access, { emails: ["one@example.com"], role: "admin", acceptUrl }, deps);
    expect(again.invitations).toHaveLength(1);
  });

  test("a full Pro roster refuses new invitations", async () => {
    const { access, deps } = await proTeam([THIRD_MEMBER]);
    await expect(
      inviteTeamMembers(access, { emails: ["late@example.com"], role: "member", acceptUrl }, deps),
    ).rejects.toMatchObject({ code: "seat_limit", status: 409 });
  });

  test("a batch larger than the free seats is refused before any email is sent", async () => {
    const { mailer, access, deps } = await proTeam();
    await expect(
      inviteTeamMembers(access, { emails: ["a@example.com", "b@example.com"], role: "member", acceptUrl }, deps),
    ).rejects.toMatchObject({ code: "seat_limit" });
    expect(mailer.sent).toHaveLength(0);
  });

  test("teams without a personal plan keep soft seats", async () => {
    const stack = standardTeam();
    stack.teams.get(TEAM_ID)!.metadata = { cmuxPlan: "team", cmuxSeats: 2 };
    const deps = { store: new MemoryInviteStore(), mailer: new MemoryInviteMailer() };
    const access = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
    if (!access.ok) throw new Error("access refused");
    const result = await inviteTeamMembers(
      access.access,
      { emails: ["a@example.com", "b@example.com", "c@example.com"], role: "member", acceptUrl },
      deps,
    );
    expect(result.invitations).toHaveLength(3);
  });
});
