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
let invitations: Array<{
  id: string;
  recipientEmail: string;
  expiresAt: Date;
  revoke: ReturnType<typeof mock>;
  resend: ReturnType<typeof mock>;
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
  getStackServerApp: () => ({ getUser }),
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
    select: () => ({
      from: () => ({
        where: () => ({
          orderBy: () => ({
            limit: mock(async () => [{ seats: 3 }]),
          }),
        }),
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

mock.module("@vercel/firewall", () => ({
  checkRateLimit: mock(async () => ({ error: null, rateLimited: false })),
}));

mock.module("resend", () => ({
  Resend: class {
    emails = { send: emailSend };
  },
}));

const inviteRoute = await import("../app/api/team/invite/route");
const revokeRoute = await import("../app/api/team/invite/revoke/route");

describe("team invite routes", () => {
  beforeEach(() => {
    members = [{ id: "user-1", primaryEmail: "member@example.com" }];
    invitations = [];
    currentUser = stackUser();
    getUser.mockClear();
    sendTeamInvitation.mockClear();
    emailSend.mockClear();
    process.env.VERCEL = "0";
  });

  test("member can create a Stack invite and receives an accept URL", async () => {
    const response = await inviteRoute.POST(request("/api/team/invite", {
      email: " Ada@Example.com ",
      locale: "en",
    }));
    const body = await response.json() as { acceptUrl: string; invitation: { email: string; id: string } };

    expect(response.status).toBe(200);
    expect(body.invitation.email).toBe("ada@example.com");
    expect(body.acceptUrl).toContain("/en/dashboard/team/accept?invitation=inv_ada%40example.com");
    expect(sendTeamInvitation).toHaveBeenCalledWith({
      email: "ada@example.com",
      callbackUrl: "https://cmux.test/en/dashboard/team/accept",
    });
    expect(emailSend).toHaveBeenCalled();
  });

  test("neutralizes an off-origin locale so invite URLs stay on-origin", async () => {
    const response = await inviteRoute.POST(request("/api/team/invite", {
      email: "ada@example.com",
      locale: "//evil.com",
    }));
    const body = await response.json() as { acceptUrl: string };

    expect(response.status).toBe(200);
    expect(new URL(body.acceptUrl).origin).toBe("https://cmux.test");
    expect(body.acceptUrl).toContain("/en/dashboard/team/accept");
    expect(sendTeamInvitation).toHaveBeenCalledWith({
      email: "ada@example.com",
      callbackUrl: "https://cmux.test/en/dashboard/team/accept",
    });
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
});

function stackUser() {
  const team = {
    id: "team-1",
    displayName: "Team One",
    listUsers: mock(async () => members),
    listInvitations: mock(async () => invitations),
    sendTeamInvitation,
  };
  return {
    id: "user-1",
    displayName: "Grace Hopper",
    primaryEmail: "member@example.com",
    selectedTeam: team,
    listTeams: mock(async () => [team]),
  };
}

function request(path: string, body: unknown): Request {
  return new Request(`https://cmux.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}
