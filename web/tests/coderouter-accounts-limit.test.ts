import { describe, expect, mock, test } from "bun:test";

import { makeCoderouterAccountsPostHandler } from "../app/api/coderouter/accounts/route";

const context = {
  ok: true as const,
  value: {
    user: { id: "user_1" },
    team: {
      teamId: "team_1",
      teamName: "Team",
      use: true,
      manageAccounts: true,
    },
  },
};

const credentialBody = JSON.stringify({
  provider: "codex",
  accessToken: "access",
  refreshToken: "refresh",
  idToken: "id",
  accountId: "acct-openai-1",
  email: "person@example.com",
  expiresAt: Date.now() + 60_000,
});

function addRequest(): Request {
  return new Request("https://coderouter.dev/api/coderouter/accounts", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: credentialBody,
  });
}

describe("coderouter account addition limit", () => {
  test("blocks connecting a fourth account without a subscription", async () => {
    const add = mock(async () => ({ accountId: "new", alreadyExists: false }));
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => context) as never,
      additionAllowed: async () => ({ allowed: false, accountCount: 3 }),
      add,
      hostedProRequired: () => true,
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(402);
    await expect(response.json()).resolves.toMatchObject({
      error: "pro_required",
    });
    expect(add).not.toHaveBeenCalled();
  });

  test("stores an account the gate allows", async () => {
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => context) as never,
      additionAllowed: async () => ({ allowed: true, accountCount: 1 }),
      add: async () => ({ accountId: "new", alreadyExists: false }),
      hostedProRequired: () => true,
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(201);
  });

  test("fails closed with a retryable error when the gate is unavailable", async () => {
    const add = mock(async () => ({ accountId: "new", alreadyExists: false }));
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => context) as never,
      additionAllowed: async () => {
        throw new Error("database unavailable");
      },
      add,
      hostedProRequired: () => true,
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toMatchObject({
      error: "entitlement_unavailable",
      retryable: true,
    });
    expect(add).not.toHaveBeenCalled();
  });

  test("skips the gate entirely when hosted billing is off", async () => {
    const additionAllowed = mock(async () => ({
      allowed: false,
      accountCount: 9,
    }));
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => context) as never,
      additionAllowed,
      add: async () => ({ accountId: "new", alreadyExists: false }),
      hostedProRequired: () => false,
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(201);
    expect(additionAllowed).not.toHaveBeenCalled();
  });
});
