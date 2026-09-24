import { describe, expect, mock, test } from "bun:test";

import { makeCoderouterAccountsPostHandler } from "../app/api/coderouter/accounts/route";

// There is no connected-account cap and no plan read. Any member may store a
// private account; sharing one with the team needs account administration.
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
  idToken: "header.eyJlbWFpbCI6ICJwZXJzb25AZXhhbXBsZS5jb20iLCAiaHR0cHM6Ly9hcGkub3BlbmFpLmNvbS9hdXRoIjogeyJjaGF0Z3B0X3VzZXJfaWQiOiAiZml4dHVyZS11c2VyIiwgImNoYXRncHRfYWNjb3VudF9pZCI6ICJhY2N0LW9wZW5haS0xIn19.signature",
  accountId: "acct-openai-1",
  email: "person@example.com",
  expiresAt: Date.now() + 60_000,
});

function addRequest(visibility?: string): Request {
  return new Request("https://coderouter.dev/api/coderouter/accounts", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: visibility ? JSON.stringify({ ...JSON.parse(credentialBody), visibility }) : credentialBody,
  });
}

// A team member without the Stack `$manage_api_keys` team permission.
const member = {
  ok: true as const,
  value: {
    user: { id: "user_1" },
    access: { kind: "user" as const, userId: "user_1" },
    team: {
      teamId: "team_1",
      teamName: "Benjamin Swerdlow's Team",
      use: true,
      manageAccounts: false,
    },
  },
};

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
    expect(add).toHaveBeenCalledWith("team_1", expect.objectContaining({ provider: "codex" }), undefined, undefined, undefined, { createdBy: "user_1", visibility: "private" });
  });

  test("a member without account administration stores a private account", async () => {
    const add = mock(async () => ({ accountId: "new", alreadyExists: false }));
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => member) as never,
      add,
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(201);
    // The write is narrowed so it can never reach a shared or foreign account.
    expect(add).toHaveBeenCalledWith("team_1", expect.objectContaining({ provider: "codex" }), undefined, undefined, undefined, {
      createdBy: "user_1",
      visibility: "private",
      access: { kind: "own-private", userId: "user_1" },
    });
  });

  test("sharing needs account administration and the refusal says what to do", async () => {
    const add = mock(async () => ({ accountId: "new", alreadyExists: false }));
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => member) as never,
      add,
    });
    const response = await POST(addRequest("team"));
    expect(response.status).toBe(403);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json();
    expect(body).toMatchObject({
      error: "forbidden",
      code: "team_permission_required",
      teamId: "team_1",
      teamName: "Benjamin Swerdlow's Team",
      permission: "$manage_api_keys",
      action: "share_account",
      retryable: false,
    });
    expect(body.options).toEqual([
      expect.objectContaining({ kind: "private", command: "cr add codex --private" }),
      expect.objectContaining({ kind: "switch_team", command: "cr org switch <team>" }),
      expect.objectContaining({ kind: "ask_admin" }),
    ]);
    expect(JSON.stringify(body)).not.toContain("refresh");
    expect(add).not.toHaveBeenCalled();
  });

  test("a member cannot overwrite an inactive shared account", async () => {
    const { CoderouterSharedAccountError } = await import("../services/coderouter/accountAdministration");
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => member) as never,
      add: async () => {
        throw new CoderouterSharedAccountError();
      },
    });
    const response = await POST(addRequest());
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({
      code: "team_permission_required",
      action: "change_shared_account",
      teamName: "Benjamin Swerdlow's Team",
    });
  });

  test("a VM token still stores team-visible accounts", async () => {
    const add = mock(async () => ({ accountId: "new", alreadyExists: false }));
    const vmAccess = { kind: "vm" as const, vmId: "vm_1", poolId: "pool_1" };
    const POST = makeCoderouterAccountsPostHandler({
      resolveContext: mock(async () => ({ ...context, value: { ...context.value, access: vmAccess } })) as never,
      add,
    });
    expect((await POST(addRequest("private"))).status).toBe(201);
    expect(add).toHaveBeenCalledTimes(1);
    expect((add.mock.calls[0] as unknown[])[5]).toEqual({
      createdBy: "user_1",
      visibility: "team",
      access: vmAccess,
    });
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
