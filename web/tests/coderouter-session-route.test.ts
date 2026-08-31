import { describe, expect, mock, test } from "bun:test";

import {
  makeCoderouterSessionGetHandler,
  makeCoderouterSessionPostHandler,
} from "../app/api/coderouter/session/route";

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

describe("coderouter hosted entitlement", () => {
  test("validates an existing principal-scoped route session cheaply", async () => {
    const authenticate = async (token: string) =>
      token === "crt_valid"
        ? { teamId: "team_1", stackUserId: "stack-user-1" }
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

  test("requires Pro or Team before issuing a hosted route token", async () => {
    const issueToken = mock(async () => ({
      token: "crt_test",
      expiresAt: new Date("2026-09-01T00:00:00Z"),
    }));
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      entitlement: mock(async () => ({
        allowed: false as const,
        basis: "pro_required" as const,
        accountCount: 5,
      })),
      issueToken,
      hostedProRequired: () => true,
    });

    const response = await POST(
      new Request("https://coderouter.dev/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(402);
    await expect(response.json()).resolves.toMatchObject({
      error: "pro_required",
    });
    expect(issueToken).not.toHaveBeenCalled();
  });

  test("issues a hosted route token on the free tier without a subscription", async () => {
    const issueToken = mock(async () => ({
      token: "crt_free",
      expiresAt: new Date("2026-09-01T00:00:00Z"),
    }));
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      entitlement: mock(async () => ({
        allowed: true as const,
        basis: "free_tier" as const,
        accountCount: 3,
      })),
      issueToken,
      hostedProRequired: () => true,
    });

    const response = await POST(
      new Request("https://coderouter.dev/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(200);
    expect(issueToken).toHaveBeenCalledWith("team_1", "user_1");
  });

  test("keeps self-hosted servers independent from hosted billing", async () => {
    const issueToken = mock(async () => ({
      token: "crt_test",
      expiresAt: new Date("2026-09-01T00:00:00Z"),
    }));
    const entitlement = mock(async () => ({
      allowed: false as const,
      basis: "pro_required" as const,
      accountCount: 5,
    }));
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      entitlement,
      issueToken,
      hostedProRequired: () => false,
    });

    const response = await POST(
      new Request("https://router.example.com/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      token: "crt_test",
      openaiBaseUrl: "https://router.example.com/v1",
    });
    expect(entitlement).not.toHaveBeenCalled();
    expect(issueToken).toHaveBeenCalledWith("team_1", "user_1");
  });

  test("fails closed when hosted entitlement storage is unavailable", async () => {
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      entitlement: mock(async () => {
        throw new Error("database unavailable");
      }),
      issueToken: mock(async () => {
        throw new Error("must not issue");
      }),
      hostedProRequired: () => true,
    });

    const response = await POST(
      new Request("https://coderouter.dev/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBeNull();
  });

  test("issues a hosted route token for a selected Team entitlement", async () => {
    const issueToken = mock(async () => ({
      token: "crt_team",
      expiresAt: new Date("2026-09-01T00:00:00Z"),
    }));
    const entitlement = mock(async (...args: unknown[]) => ({
      allowed: args[0] === "user_1" && args[1] === "team_1",
      basis: "subscription" as const,
      accountCount: 5,
    }));
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      entitlement: entitlement as never,
      issueToken,
      hostedProRequired: () => true,
    });

    const response = await POST(
      new Request("https://coderouter.dev/api/coderouter/session", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(200);
    expect(entitlement).toHaveBeenCalledWith("user_1", "team_1");
    expect(issueToken).toHaveBeenCalledWith("team_1", "user_1");
  });
});
