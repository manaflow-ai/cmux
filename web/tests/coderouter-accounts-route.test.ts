import { describe, expect, mock, test } from "bun:test";

import { makeCoderouterAccountsPostHandler } from "../app/api/coderouter/accounts/route";

// Access is team membership only. There is no connected-account cap and no
// plan read: a resolved member context goes straight to the account store.
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

describe("coderouter account addition", () => {
  test("stores an account for any team member with no account cap", async () => {
    const add = mock(async () => ({ accountId: "new", alreadyExists: false }));
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => context) as never,
      add,
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(201);
    await expect(response.json()).resolves.toEqual({
      accountId: "new",
      alreadyExists: false,
    });
    expect(add).toHaveBeenCalledTimes(1);
    expect(add).toHaveBeenCalledWith("team_1", expect.objectContaining({ provider: "codex" }));
  });

  test("re-importing an existing account is a 200, not a conflict", async () => {
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => context) as never,
      add: async () => ({ accountId: "existing", alreadyExists: true }),
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(200);
  });

  test("a non-member never reaches the account store", async () => {
    const add = mock(async () => ({ accountId: "new", alreadyExists: false }));
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => ({
        ok: false as const,
        response: Response.json({ error: "team_not_found" }, { status: 403 }),
      })) as never,
      add,
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(403);
    expect(add).not.toHaveBeenCalled();
  });

  test("fails closed with a retryable error when the account store is unavailable", async () => {
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => context) as never,
      add: async () => {
        throw new Error("database unavailable");
      },
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("5");
    await expect(response.json()).resolves.toMatchObject({
      error: "account_store_unavailable",
      retryable: true,
    });
  });
});
