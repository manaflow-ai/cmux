import { beforeEach, describe, expect, mock, test } from "bun:test";

// Import real modules so the process-wide mock.module overrides below only
// replace the specific exports the test controls, never dropping the rest (bun
// mock.module leaks into every later-sorted test file for the whole run).
const errorsModule = await import("../services/errors");
const dbClientModule = await import("../db/client");
const billingProModule = await import("../services/billing/pro");
const stackModule = await import("../app/lib/stack");

let currentUser: ReturnType<typeof stackUser> | null = null;
let members: Array<{ id: string; primaryEmail: string }> = [];
let adminIds = new Set<string>();
let inviteRoleRows = new Map<string, { role: "admin" | "member"; stackTeamId: string }>();
let invitations: Array<{
  id: string;
  recipientEmail: string;
  expiresAt: Date;
  revoke: ReturnType<typeof mock>;
  resend?: ReturnType<typeof mock>;
  send?: ReturnType<typeof mock>;
}> = [];
const sendTeamInvitation = mock(async (options: unknown) => {
  const { email } = options as { email: string; callbackUrl: string };
  const invitation = {
    id: `inv_${email}`,
    recipientEmail: email,
    expiresAt: new Date("2027-01-01T00:00:00Z"),
    revoke: mock(async () => undefined),
    resend: mock(async () => undefined),
  };
  invitations.unshift(invitation);
  return invitation;
});
const getUser = mock(async () => currentUser);
const emailSend = mock(async () => ({ error: null }));

mock.module("../app/lib/stack", () => ({
  ...stackModule,
  getStackServerApp: () => ({
    getUser,
    listTeamMemberPermissions: mock(async () =>
      Array.from(adminIds).map((userId) => ({ userId, permissionId: "team_admin" }))
    ),
  }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

// drizzle-orm and db/schema are left real: the mocked cloudDb below ignores the
// built query, so real operators/tables are harmless here and mocking them
// process-wide would corrupt every later db test.

mock.module("../app/env", () => ({
  env: {
    RESEND_API_KEY: "resend-test",
    CMUX_FEEDBACK_FROM_EMAIL: "austin@manaflow.ai",
    CMUX_FEEDBACK_RATE_LIMIT_ID: "team-invites-test",
  },
}));

mock.module("../db/client", () => ({
  ...dbClientModule,
  cloudDb: () => ({
    select: (selection: Record<string, unknown>) => ({
      from: () => ({
        where: () => ({
          orderBy: () => ({
            limit: mock(async () => [{ seats: 3 }]),
          }),
          limit: mock(async () => {
            if ("role" in selection) {
              const row = Array.from(inviteRoleRows.values())[0];
              return row ? [{ role: row.role }] : [];
            }
            return [{ seats: 3 }];
          }),
        }),
      }),
    }),
    insert: () => ({
      values: (row: { invitationId: string; stackTeamId: string; role: "admin" | "member" }) => ({
        onConflictDoUpdate: mock(async () => {
          inviteRoleRows.set(row.invitationId, { role: row.role, stackTeamId: row.stackTeamId });
        }),
      }),
    }),
    update: () => ({
      set: () => ({
        where: mock(async () => undefined),
      }),
    }),
  }),
}));

mock.module("../services/billing/pro", () => ({
  ...billingProModule,
  ACTIVE_STRIPE_PRO_STATUSES: ["active", "trialing"],
  TEAM_PLAN_ID: "team",
}));

// bun's mock.module replaces the module process-wide for the whole run, so it
// must carry EVERY export other test files import (e.g. testflight-service
// relies on captureAscError). Spreading the real module avoids dropping exports.
mock.module("../services/errors", () => ({
  ...errorsModule,
  captureBillingError: mock(() => undefined),
}));

// Do NOT mock @vercel/firewall here: these tests run with VERCEL="0", so
// enforceTeamInviteRateLimit early-returns and never calls checkRateLimit. bun
// applies mock.module process-wide (last registration wins), so a mock here
// would override notifications-push-route.test.ts's own checkRateLimit mock and
// break its rate-limit assertion on CI.

mock.module("resend", () => ({
  Resend: class {
    emails = { send: emailSend };
  },
}));

const inviteRoute = await import("../app/api/team/invite/route");
const resendRoute = await import("../app/api/team/invite/resend/route");
const revokeRoute = await import("../app/api/team/invite/revoke/route");
const removeRoute = await import("../app/api/team/members/remove/route");
const roleRoute = await import("../app/api/team/members/role/route");
const teamRoute = await import("../app/api/team/route");

describe("team invite routes", () => {
  beforeEach(() => {
    members = [{ id: "user-1", primaryEmail: "member@example.com" }];
    adminIds = new Set(["user-1"]);
    inviteRoleRows = new Map();
    invitations = [];
    currentUser = stackUser();
    getUser.mockClear();
    sendTeamInvitation.mockClear();
    emailSend.mockClear();
    process.env.VERCEL = "0";
  });

  test("admin can create a Stack invite and receives an accept URL", async () => {
    const response = await inviteRoute.POST(request("/api/team/invite", {
      email: " Ada@Example.com ",
      locale: "en",
    }));
    const body = await response.json() as {
      acceptUrl: string;
      invitation: { email: string; id: string; role: string };
    };

    expect(response.status).toBe(200);
    expect(body.invitation.email).toBe("ada@example.com");
    expect(body.invitation.role).toBe("member");
    expect(body.acceptUrl).toContain("/en/dashboard/team/accept?invitation=inv_ada%40example.com");
    expect(sendTeamInvitation).toHaveBeenCalledWith({
      email: "ada@example.com",
      callbackUrl: "https://cmux.test/en/dashboard/team/accept",
    });
    expect(emailSend).toHaveBeenCalled();
  });

  test("invite as admin stores the server-assigned role", async () => {
    const response = await inviteRoute.POST(request("/api/team/invite", {
      email: "admin@example.com",
      locale: "en",
      role: "admin",
    }));
    const body = await response.json() as { invitation: { id: string; role: string } };

    expect(response.status).toBe(200);
    expect(body.invitation.role).toBe("admin");
    expect(inviteRoleRows.get(body.invitation.id)?.role).toBe("admin");
  });

  test("neutralizes an off-origin locale and spoofed Host so invite URLs stay on trusted origin", async () => {
    Object.assign(process.env, { NODE_ENV: "production" });
    const response = await inviteRoute.POST(new Request("https://evil.example/api/team/invite", {
      method: "POST",
      headers: { "content-type": "application/json", host: "evil.example" },
      body: JSON.stringify({
      email: "ada@example.com",
      locale: "//evil.com",
      }),
    }));
    const body = await response.json() as { acceptUrl: string };

    expect(response.status).toBe(200);
    expect(new URL(body.acceptUrl).origin).toBe("https://cmux.com");
    expect(body.acceptUrl).toContain("/en/dashboard/team/accept");
    expect(sendTeamInvitation).toHaveBeenCalledWith({
      email: "ada@example.com",
      callbackUrl: "https://cmux.com/en/dashboard/team/accept",
    });
    Object.assign(process.env, { NODE_ENV: "test" });
  });

  test("rejects non-members before creating an invitation", async () => {
    members = [{ id: "other", primaryEmail: "other@example.com" }];

    const response = await inviteRoute.POST(request("/api/team/invite", {
      email: "ada@example.com",
      locale: "en",
    }));
    const body = await response.json();

    expect(response.status).toBe(403);
    expect(body).toEqual({ error: "team_not_found" });
    expect(sendTeamInvitation).not.toHaveBeenCalled();
  });

  test("rejects invalid email", async () => {
    const response = await inviteRoute.POST(request("/api/team/invite", {
      email: "not-an-email",
      locale: "en",
    }));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_email" });
    expect(sendTeamInvitation).not.toHaveBeenCalled();
  });

  test("revoke uses the invitation action and reconciles from team state", async () => {
    const revoke = mock(async () => undefined);
    invitations = [{
      id: "inv_1",
      recipientEmail: "ada@example.com",
      expiresAt: new Date("2027-01-01T00:00:00Z"),
      revoke,
      resend: mock(async () => undefined),
    }];

    const response = await revokeRoute.POST(request("/api/team/invite/revoke", {
      invitationId: "inv_1",
    }));
    const body = await response.json() as { invitations: unknown[] };

    expect(response.status).toBe(200);
    expect(revoke).toHaveBeenCalled();
    expect(body.invitations).toHaveLength(1);
  });

  test("members are forbidden from mutating team management", async () => {
    members = [
      { id: "user-1", primaryEmail: "member@example.com" },
      { id: "admin-1", primaryEmail: "admin@example.com" },
      { id: "target-1", primaryEmail: "target@example.com" },
    ];
    adminIds = new Set(["admin-1"]);
    invitations = [{
      id: "inv_1",
      recipientEmail: "ada@example.com",
      expiresAt: new Date("2027-01-01T00:00:00Z"),
      revoke: mock(async () => undefined),
      resend: mock(async () => undefined),
    }];

    const cases = [
      inviteRoute.POST(request("/api/team/invite", { email: "ada@example.com", locale: "en" })),
      revokeRoute.POST(request("/api/team/invite/revoke", { invitationId: "inv_1" })),
      resendRoute.POST(request("/api/team/invite/resend", { invitationId: "inv_1", locale: "en" })),
      removeRoute.POST(request("/api/team/members/remove", { memberId: "target-1" })),
      roleRoute.POST(request("/api/team/members/role", { memberId: "target-1", role: "admin" })),
      teamRoute.POST(request("/api/team", { action: "rename", displayName: "New Name" })),
    ];

    for (const response of await Promise.all(cases)) {
      expect(response.status).toBe(403);
      expect(await response.json()).toEqual({ error: "not_team_admin" });
    }
  });

  test("member can leave the team", async () => {
    members = [
      { id: "user-1", primaryEmail: "member@example.com" },
      { id: "admin-1", primaryEmail: "admin@example.com" },
    ];
    adminIds = new Set(["admin-1"]);
    currentUser = stackUser();

    const response = await removeRoute.POST(request("/api/team/members/remove", { memberId: "user-1" }));

    expect(response.status).toBe(200);
    expect(currentUser?.selectedTeam.removeUser).toHaveBeenCalledWith("user-1");
  });

  test("last admin cannot be removed or demoted", async () => {
    members = [
      { id: "user-1", primaryEmail: "member@example.com" },
      { id: "target-1", primaryEmail: "target@example.com" },
    ];
    adminIds = new Set(["user-1"]);

    const removeResponse = await removeRoute.POST(request("/api/team/members/remove", { memberId: "user-1" }));
    const demoteResponse = await roleRoute.POST(request("/api/team/members/role", {
      memberId: "user-1",
      role: "member",
    }));

    expect(removeResponse.status).toBe(400);
    expect(await removeResponse.json()).toEqual({ error: "cannot_remove_last_admin" });
    expect(demoteResponse.status).toBe(400);
    expect(await demoteResponse.json()).toEqual({ error: "cannot_demote_last_admin" });
  });

  test("admin can promote and demote members", async () => {
    members = [
      { id: "user-1", primaryEmail: "member@example.com" },
      { id: "target-1", primaryEmail: "target@example.com" },
    ];
    adminIds = new Set(["user-1"]);

    const promoteResponse = await roleRoute.POST(request("/api/team/members/role", {
      memberId: "target-1",
      role: "admin",
    }));
    const demoteResponse = await roleRoute.POST(request("/api/team/members/role", {
      memberId: "target-1",
      role: "member",
    }));

    expect(promoteResponse.status).toBe(200);
    expect(demoteResponse.status).toBe(200);
    expect(adminIds.has("target-1")).toBe(false);
  });

  test("resend returns an error when no resend path can send email", async () => {
    Object.assign(process.env, { NODE_ENV: "test" });
    invitations = [{
      id: "inv_1",
      recipientEmail: "ada@example.com",
      expiresAt: new Date("2027-01-01T00:00:00Z"),
      revoke: undefined as unknown as ReturnType<typeof mock>,
      resend: undefined,
      send: undefined,
    }];

    const response = await resendRoute.POST(request("/api/team/invite/resend", {
      invitationId: "inv_1",
      locale: "en",
    }));

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "email_unavailable" });
    expect(emailSend).not.toHaveBeenCalled();
  });
});

function stackUser() {
  const team = {
    id: "team-1",
    displayName: "Team One",
    listUsers: mock(async () => members.map((member) => stackMember(member.id, member.primaryEmail))),
    listInvitations: mock(async () => invitations),
    sendTeamInvitation,
    removeUser: mock(async (...args: unknown[]) => {
      const userId = String(args[0]);
      members = members.filter((member) => member.id !== userId);
    }),
    update: mock(async () => undefined),
  };
  return {
    id: "user-1",
    displayName: "Grace Hopper",
    primaryEmail: "member@example.com",
    selectedTeam: team,
    listTeams: mock(async () => [team]),
    hasPermission: mock(async (...args: unknown[]) => {
      const permissionId = String(args[1]);
      return permissionId === "team_admin" && adminIds.has("user-1");
    }),
    grantPermission: mock(async (...args: unknown[]) => {
      const permissionId = String(args[1]);
      if (permissionId === "team_admin") adminIds.add("user-1");
    }),
  };
}

function stackMember(id: string, primaryEmail: string) {
  return {
    id,
    primaryEmail,
    displayName: primaryEmail,
    profileImageUrl: null,
    hasPermission: mock(async (...args: unknown[]) => {
      const permissionId = String(args[1]);
      return permissionId === "team_admin" && adminIds.has(id);
    }),
    grantPermission: mock(async (...args: unknown[]) => {
      const permissionId = String(args[1]);
      if (permissionId === "team_admin") adminIds.add(id);
    }),
    revokePermission: mock(async (...args: unknown[]) => {
      const permissionId = String(args[1]);
      if (permissionId === "team_admin") adminIds.delete(id);
    }),
  };
}

function request(path: string, body: unknown): Request {
  return new Request(`https://cmux.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}
