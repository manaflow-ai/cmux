import { describe, expect, mock, test } from "bun:test";

import { makeApiKeyHandlers } from "../app/api/coderouter/api-keys/route";

// Account administration (the Stack `$manage_api_keys` team permission) gates
// team-wide actions. Each refusal names the team, the permission, and the
// ways forward, so `cr` can print a next step instead of a bare "forbidden".
const TEAM = { teamId: "team_1", teamName: "Benjamin Swerdlow's Team", use: true };
const member = {
  ok: true as const,
  value: {
    user: { id: "user_2" },
    access: { kind: "user" as const, userId: "user_2" },
    team: { ...TEAM, manageAccounts: false },
  },
};

async function expectPermissionRequired(response: Response, action: string, optionKinds: readonly string[]) {
  expect(response.status).toBe(403);
  expect(response.headers.get("cache-control")).toBe("no-store");
  const body = await response.json();
  expect(body).toMatchObject({
    error: "forbidden",
    code: "team_permission_required",
    teamId: "team_1",
    teamName: "Benjamin Swerdlow's Team",
    permission: "$manage_api_keys",
    action,
    retryable: false,
  });
  expect(typeof body.message).toBe("string");
  expect(body.options.map((option: { kind: string }) => option.kind)).toEqual(optionKinds);
  for (const option of body.options) expect(typeof option.message).toBe("string");
  return body;
}

describe("coderouter team permission refusals", () => {
  test("creating an API key", async () => {
    const create = mock(async () => {
      throw new Error("must not be called");
    });
    const { POST } = makeApiKeyHandlers({
      resolve: (async () => member) as never,
      list: async () => [],
      create,
      usage: async () => ({ kind: "ready", byKey: {} }),
    });
    const response = await POST(new Request("https://coderouter.dev/api/coderouter/api-keys", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ label: "ci" }),
    }));
    const body = await expectPermissionRequired(response, "manage_api_keys", ["switch_team", "ask_admin"]);
    expect(body.options[0].command).toBe("cr org switch <team>");
    expect(create).not.toHaveBeenCalled();
  });

  test("revoking an API key", async () => {
    const { makeApiKeyRevokeHandler } = await import("../app/api/coderouter/api-keys/[keyId]/route");
    const revoke = mock(async () => true);
    const DELETE = makeApiKeyRevokeHandler({ resolve: (async () => member) as never, revoke });
    const response = await DELETE(
      new Request("https://coderouter.dev/api/coderouter/api-keys/00000000-0000-4000-8000-000000000042", { method: "DELETE" }),
      { params: Promise.resolve({ keyId: "00000000-0000-4000-8000-000000000042" }) },
    );
    await expectPermissionRequired(response, "manage_api_keys", ["switch_team", "ask_admin"]);
    expect(revoke).not.toHaveBeenCalled();
  });

  test("changing an account's team visibility", async () => {
    const { makeAccountSharingHandler } = await import("../app/api/coderouter/accounts/[accountId]/sharing/route");
    const change = mock(async () => true);
    const PATCH = makeAccountSharingHandler({ resolve: (async () => member) as never, change: change as never });
    const response = await PATCH(
      new Request("https://coderouter.dev/api/coderouter/accounts/00000000-0000-4000-8000-000000000001/sharing", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ family: "claude", visibility: "team" }),
      }),
      { params: Promise.resolve({ accountId: "00000000-0000-4000-8000-000000000001" }) },
    );
    await expectPermissionRequired(response, "share_account", ["private", "switch_team", "ask_admin"]);
    expect(change).not.toHaveBeenCalled();
  });
});
