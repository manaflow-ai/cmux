import { describe, expect, mock, test } from "bun:test";

import {
  makeCoderouterSessionGetHandler,
  makeCoderouterSessionPostHandler,
} from "../app/api/coderouter/session/route";

// Access is team membership only. The context resolver already rejected
// non-members, so a resolved context means a token is issued: no plan,
// subscription, or account-count read stands between membership and a session.
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

describe("coderouter route session", () => {
  test("validates an existing principal-scoped route session cheaply", async () => {
    const authenticate = async (token: string) =>
      token === "crt_valid"
        ? { teamId: "team_1", stackUserId: "stack-user-1", vmId: null }
        : null;
    const GET = makeCoderouterSessionGetHandler(authenticate);

    const valid = await GET(new Request(
      "https://coderouter.dev/api/coderouter/session",
      { headers: { authorization: "Bearer crt_valid" } },
    ));
    const invalid = await GET(new Request(
      "https://coderouter.dev/api/coderouter/session",
      { headers: { authorization: "Bearer crt_invalid" } },
    ));

    expect(valid.status).toBe(204);
    expect(invalid.status).toBe(401);
  });

  test("issues a hosted route token to any team member with no plan check", async () => {
    const issueToken = mock(async () => ({
      token: "crt_test",
      expiresAt: new Date("2026-09-01T00:00:00Z"),
    }));
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      issueToken,
    });

    const response = await POST(
      new Request("https://coderouter.dev/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    await expect(response.json()).resolves.toMatchObject({
      teamId: "team_1",
      token: "crt_test",
      expiresAt: "2026-09-01T00:00:00.000Z",
      openaiBaseUrl: "https://coderouter.dev/v1",
    });
    expect(issueToken).toHaveBeenCalledWith("team_1", "user_1");
  });

  test("derives the OpenAI base URL from the server that issued the session", async () => {
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      issueToken: async () => ({
        token: "crt_test",
        expiresAt: new Date("2026-09-01T00:00:00Z"),
      }),
    });

    const response = await POST(
      new Request("https://router.example.com/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      openaiBaseUrl: "https://router.example.com/v1",
    });
  });

  test("a non-member never reaches token issuance", async () => {
    const issueToken = mock(async () => {
      throw new Error("must not issue");
    });
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => ({
        ok: false as const,
        response: Response.json({ error: "team_not_found" }, { status: 403 }),
      })) as never,
      issueToken,
    });

    const response = await POST(
      new Request("https://coderouter.dev/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(403);
    await expect(response.json()).resolves.toEqual({ error: "team_not_found" });
    expect(issueToken).not.toHaveBeenCalled();
  });

  test("fails closed with a retryable error when token storage is unavailable", async () => {
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      issueToken: mock(async () => {
        throw new Error("database unavailable");
      }),
    });

    const response = await POST(
      new Request("https://coderouter.dev/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("5");
    await expect(response.json()).resolves.toMatchObject({
      error: "session_unavailable",
      retryable: true,
    });
  });
});
