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

  test("requires Pro before issuing a hosted route token", async () => {
    const issueToken = mock(async () => ({
      token: "crt_test",
      expiresAt: new Date("2026-09-01T00:00:00Z"),
    }));
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      hasActivePro: mock(async () => false),
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

  test("keeps self-hosted servers independent from hosted billing", async () => {
    const issueToken = mock(async () => ({
      token: "crt_test",
      expiresAt: new Date("2026-09-01T00:00:00Z"),
    }));
    const hasActivePro = mock(async () => false);
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      hasActivePro,
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
    expect(hasActivePro).not.toHaveBeenCalled();
    expect(issueToken).toHaveBeenCalledWith("team_1", "user_1");
  });

  test("fails closed when hosted entitlement storage is unavailable", async () => {
    const POST = makeCoderouterSessionPostHandler({
      resolveContext: mock(async () => context) as never,
      hasActivePro: mock(async () => {
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
});
