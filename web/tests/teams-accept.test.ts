import { describe, expect, test } from "bun:test";
import { acceptTeamInvitationCode } from "../services/teams/accept";
import { requireTeamAccess } from "../services/teams/access";
import { inviteTeamMembers, resendTeamInvitation } from "../services/teams/invitations";
import { TeamApiError, TeamServiceUnavailableError } from "../services/teams/errors";
import { createInvitationCodeClient, type InvitationCodeClient } from "../services/teams/invitationCode";
import { ADMIN_ID, MemoryInviteStore, MemoryTeamSeatSync, OUTSIDER_ID, standardTeam, TEAM_ID } from "./teams-fixture";

const INVITEE_EMAIL = "invitee@example.com";

/** Stack's code endpoints: `details` names the team, `accept` consumes one invitation. */
function codeClient(input: {
  teamId?: string;
  onAccept?: () => void;
  detailsFailure?: "email_mismatch" | "invalid" | "unavailable";
  acceptFailure?: "email_mismatch" | "invalid" | "unavailable";
}): InvitationCodeClient & { tokens: string[] } {
  const tokens: string[] = [];
  return {
    tokens,
    async details(_code, accessToken) {
      tokens.push(accessToken);
      if (input.detailsFailure) return { ok: false, failure: input.detailsFailure };
      return { ok: true, value: { teamId: input.teamId ?? TEAM_ID, teamDisplayName: "Acme" } };
    },
    async accept(_code, accessToken) {
      tokens.push(accessToken);
      if (input.acceptFailure) return { ok: false, failure: input.acceptFailure };
      input.onAccept?.();
      return { ok: true, value: null };
    },
  };
}

function inviteeStack() {
  const stack = standardTeam();
  stack.users.set(OUTSIDER_ID, {
    id: OUTSIDER_ID,
    email: INVITEE_EMAIL,
    verifiedEmails: [INVITEE_EMAIL, "second@example.com"],
    selectedTeamId: null,
  });
  return stack;
}

function acceptRequest(): Request {
  return new Request("https://cmux.test/api/teams/accept", {
    method: "POST",
    headers: { authorization: "Bearer native-access", "x-stack-refresh-token": "native-refresh" },
  });
}

/** A stored role as cmux leaves it after sending: bound to the invitation it went out with. */
async function storeWithRole(email: string, role: "admin" | "member", stackInvitationId: string) {
  const store = new MemoryInviteStore();
  await store.upsertInviteRole({ stackTeamId: TEAM_ID, email, role, invitedByUserId: ADMIN_ID });
  await store.bindInviteRoleInvitation(TEAM_ID, email, stackInvitationId);
  return store;
}

async function failure(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof TeamApiError) return `${error.status}:${error.code}`;
    if (error instanceof TeamServiceUnavailableError) return "503:service_unavailable";
    throw error;
  }
  return "ok";
}

describe("accepting an email invitation", () => {
  test("applies a stored admin role on the exact team and consumes the role row", async () => {
    const stack = inviteeStack();
    const invitation = stack.addInvitation(TEAM_ID, INVITEE_EMAIL);
    const store = await storeWithRole(INVITEE_EMAIL, "admin", invitation.id);
    const codes = codeClient({ onAccept: () => stack.consumeInvitation(invitation.id, OUTSIDER_ID) });

    const result = await acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", { stack: stack.app(), codes, store, seats: new MemoryTeamSeatSync() });

    expect(result).toEqual({ teamId: TEAM_ID, role: "admin" });
    expect(stack.grantsOf(TEAM_ID, OUTSIDER_ID).has("team_admin")).toBe(true);
    expect(store.roles.size).toBe(0);
    expect(stack.users.get(OUTSIDER_ID)!.selectedTeamId).toBe(TEAM_ID);
    // The caller's authoritative token, never a server credential, uses the code.
    expect(codes.tokens).toEqual(["caller-access-token", "caller-access-token"]);
  });

  test("defaults to member when no role was stored", async () => {
    const stack = inviteeStack();
    const invitation = stack.addInvitation(TEAM_ID, INVITEE_EMAIL);
    const codes = codeClient({ onAccept: () => stack.consumeInvitation(invitation.id, OUTSIDER_ID) });
    const result = await acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", {
      stack: stack.app(),
      codes,
      store: new MemoryInviteStore(),
    });
    expect(result.role).toBe("member");
    expect(stack.calls.some((call) => call.startsWith("grant:"))).toBe(false);
  });

  test("picks the consumed invitation when the user has two pending ones", async () => {
    const stack = inviteeStack();
    const second = stack.addInvitation(TEAM_ID, "second@example.com");
    const consumed = stack.addInvitation(TEAM_ID, INVITEE_EMAIL);
    const store = await storeWithRole("second@example.com", "admin", second.id);
    await store.upsertInviteRole({ stackTeamId: TEAM_ID, email: INVITEE_EMAIL, role: "member", invitedByUserId: ADMIN_ID });
    const codes = codeClient({ onAccept: () => stack.consumeInvitation(consumed.id, OUTSIDER_ID) });

    const result = await acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", { stack: stack.app(), codes, store, seats: new MemoryTeamSeatSync() });

    // The admin invitation to the other address was not the one used.
    expect(result.role).toBe("member");
    expect(stack.grantsOf(TEAM_ID, OUTSIDER_ID).has("team_admin")).toBe(false);
    expect(store.roles.has(`${TEAM_ID}:second@example.com`)).toBe(true);
  });

  test("an unidentifiable consumed invitation never escalates", async () => {
    const stack = inviteeStack();
    const pending = stack.addInvitation(TEAM_ID, INVITEE_EMAIL);
    const store = await storeWithRole(INVITEE_EMAIL, "admin", pending.id);
    // Stack added the member but the invitation list did not change.
    const codes = codeClient({
      onAccept: () => {
        stack.teams.get(TEAM_ID)!.members.add(OUTSIDER_ID);
      },
    });
    const result = await acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", { stack: stack.app(), codes, store, seats: new MemoryTeamSeatSync() });
    expect(result.role).toBe("member");
    expect(stack.grantsOf(TEAM_ID, OUTSIDER_ID).has("team_admin")).toBe(false);
  });

  test("an admin role stored on another team is not applied", async () => {
    const stack = inviteeStack();
    const invitation = stack.addInvitation(TEAM_ID, INVITEE_EMAIL);
    const store = new MemoryInviteStore();
    await store.upsertInviteRole({
      stackTeamId: "99999999-9999-4999-8999-999999999999",
      email: INVITEE_EMAIL,
      role: "admin",
      invitedByUserId: ADMIN_ID,
    });
    const codes = codeClient({ onAccept: () => stack.consumeInvitation(invitation.id, OUTSIDER_ID) });
    const result = await acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", { stack: stack.app(), codes, store, seats: new MemoryTeamSeatSync() });
    expect(result.role).toBe("member");
  });

  test("maps Stack code failures to 409 email_mismatch and 410 invitation_invalid", async () => {
    const stack = inviteeStack();
    const store = new MemoryInviteStore();
    const run = (codes: InvitationCodeClient) =>
      failure(acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", { stack: stack.app(), codes, store, seats: new MemoryTeamSeatSync() }));
    expect(await run(codeClient({ detailsFailure: "email_mismatch" }))).toBe("409:email_mismatch");
    expect(await run(codeClient({ detailsFailure: "invalid" }))).toBe("410:invitation_invalid");
    expect(await run(codeClient({ acceptFailure: "invalid" }))).toBe("410:invitation_invalid");
    expect(await run(codeClient({ acceptFailure: "unavailable" }))).toBe("503:service_unavailable");
    expect(await run(codeClient({ teamId: "99999999-9999-4999-8999-999999999999" }))).toBe("410:invitation_invalid");
  });

  test("refuses to grant when Stack did not actually add the member", async () => {
    const stack = inviteeStack();
    const pending = stack.addInvitation(TEAM_ID, INVITEE_EMAIL);
    const store = await storeWithRole(INVITEE_EMAIL, "admin", pending.id);
    const codes = codeClient({});
    expect(await failure(acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", { stack: stack.app(), codes, store, seats: new MemoryTeamSeatSync() })))
      .toBe("503:service_unavailable");
    expect(stack.grantsOf(TEAM_ID, OUTSIDER_ID).has("team_admin")).toBe(false);
  });

  test("a session without an access token is unauthorized", async () => {
    const stack = inviteeStack();
    stack.accessToken = null;
    expect(await failure(acceptTeamInvitationCode(acceptRequest(), OUTSIDER_ID, "code", {
      stack: stack.app(),
      codes: codeClient({}),
      store: new MemoryInviteStore(),
    }))).toBe("401:unauthorized");
  });
});

describe("Stack invitation-code client", () => {
  const environment = {
    NEXT_PUBLIC_STACK_PROJECT_ID: "project-1",
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "pck_1",
  };

  function respond(body: unknown, headers: Record<string, string> = {}) {
    const calls: { url: string; init: RequestInit }[] = [];
    const client = createInvitationCodeClient({
      environment,
      fetch: async (url, init) => {
        calls.push({ url, init });
        return new Response(JSON.stringify(body), { status: 200, headers });
      },
    });
    return { client, calls };
  }

  test("reads the team id from the details endpoint with the caller's client headers", async () => {
    const { client, calls } = respond({ team_id: TEAM_ID, team_display_name: "Acme" });
    expect(await client.details("the-code", "user-token")).toEqual({
      ok: true,
      value: { teamId: TEAM_ID, teamDisplayName: "Acme" },
    });
    expect(calls[0]!.url.endsWith("/api/v1/team-invitations/accept/details")).toBe(true);
    const headers = calls[0]!.init.headers as Record<string, string>;
    expect(headers["x-stack-access-type"]).toBe("client");
    expect(headers["x-stack-access-token"]).toBe("user-token");
    expect(headers["x-stack-publishable-client-key"]).toBe("pck_1");
    expect(Object.keys(headers).some((name) => name.includes("secret"))).toBe(false);
    expect(calls[0]!.init.body).toBe(JSON.stringify({ code: "the-code" }));
  });

  test("omits the publishable key headers when none is configured", async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    const client = createInvitationCodeClient({
      environment: { NEXT_PUBLIC_STACK_PROJECT_ID: "project-1" },
      fetch: async (url, init) => {
        calls.push({ url, init });
        return new Response(JSON.stringify({ team_id: TEAM_ID, team_display_name: "Acme" }), { status: 200 });
      },
    });
    expect(await client.details("the-code", "user-token")).toEqual({
      ok: true,
      value: { teamId: TEAM_ID, teamDisplayName: "Acme" },
    });
    const headers = calls[0]!.init.headers as Record<string, string>;
    expect(headers["x-stack-project-id"]).toBe("project-1");
    expect(Object.keys(headers).some((name) => name.includes("publishable"))).toBe(false);
  });

  test("maps known errors from override-status responses", async () => {
    const mismatch = respond(
      { code: "TEAM_INVITATION_EMAIL_MISMATCH" },
      { "x-stack-actual-status": "403", "x-stack-known-error": "TEAM_INVITATION_EMAIL_MISMATCH" },
    );
    expect(await mismatch.client.accept("c", "t")).toEqual({ ok: false, failure: "email_mismatch" });
    const used = respond({ code: "VERIFICATION_CODE_ALREADY_USED" }, { "x-hexclave-actual-status": "409", "x-hexclave-known-error": "VERIFICATION_CODE_ALREADY_USED" });
    expect(await used.client.accept("c", "t")).toEqual({ ok: false, failure: "invalid" });
    const broken = respond({ message: "boom" }, { "x-stack-actual-status": "500" });
    expect(await broken.client.accept("c", "t")).toEqual({ ok: false, failure: "unavailable" });
    const missingTeam = respond({ team_display_name: "Acme" });
    expect(await missingTeam.client.details("c", "t")).toEqual({ ok: false, failure: "unavailable" });
  });

  test("a transport failure is unavailable, not invalid", async () => {
    const client = createInvitationCodeClient({
      environment,
      fetch: async () => {
        throw new Error("network");
      },
    });
    expect(await client.accept("c", "t")).toEqual({ ok: false, failure: "unavailable" });
  });
});
