import { describe, expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";

import {
  handleShareSessionEnd,
  type ShareSessionEndDeps,
} from "../app/api/share/sessions/[code]/route";
import {
  revokeShareSession,
  ShareSessionRelayError,
} from "../services/share/session";
import type { AuthedUser } from "../services/vms/auth";

const NOW = 1_700_000_000;
const USER: AuthedUser = {
  id: "u-1",
  displayName: "Test User",
  primaryEmail: "user@example.com",
  billingCustomerType: "user",
  billingTeamId: "u-1",
  selectedTeamId: null,
  teams: [],
  teamIds: [],
  userBillingPlanId: null,
  billingPlanId: null,
};

function deps(
  overrides: Partial<ShareSessionEndDeps> = {},
): ShareSessionEndDeps {
  return {
    verifyNativeRequest: async () => USER,
    signingKey: () => generateKeyPairSync("ed25519").privateKey,
    nowSeconds: () => NOW,
    revokeSession: async () => {},
    checkRateLimit: async () => ({ rateLimited: false }),
    rateLimitRuleId: () => undefined,
    isVercel: () => false,
    ...overrides,
  };
}

function request(): Request {
  return new Request("https://cmux.com/api/share/sessions/code12345678", {
    method: "DELETE",
  });
}

describe("DELETE /api/share/sessions/[code]", () => {
  test("mints a non-creating host claim and revokes the Durable Object session", async () => {
    let claims: Record<string, unknown> | null = null;
    const response = await handleShareSessionEnd(
      request(),
      "code12345678",
      deps({
        revokeSession: async ({ code, token }) => {
          expect(code).toBe("code12345678");
          const [, payload] = token.split(".");
          claims = JSON.parse(
            Buffer.from(payload ?? "", "base64url").toString(),
          ) as Record<string, unknown>;
        },
      }),
    );

    expect(response.status).toBe(204);
    expect(claims).toMatchObject({
      sub: USER.id,
      code: "code12345678",
      host: true,
    });
    expect(claims).not.toHaveProperty("create");
  });

  test("is idempotent when the relay session is already absent", async () => {
    const response = await handleShareSessionEnd(
      request(),
      "code12345678",
      deps({
        revokeSession: async () => {
          throw new ShareSessionRelayError({
            code: "share_session_not_found",
          });
        },
      }),
    );

    expect(response.status).toBe(204);
  });

  test("requires native authentication", async () => {
    const response = await handleShareSessionEnd(
      request(),
      "code12345678",
      deps({
        verifyNativeRequest: async () => null,
        revokeSession: async () => {
          throw new Error("must not revoke without native auth");
        },
      }),
    );

    expect(response.status).toBe(401);
  });

  test("surfaces a relay outage without logging credentials", async () => {
    const response = await handleShareSessionEnd(
      request(),
      "code12345678",
      deps({
        revokeSession: async () => {
          throw new ShareSessionRelayError({
            code: "share_worker_unavailable",
          });
        },
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "share_worker_unavailable",
    });
  });
});

describe("share relay revocation client", () => {
  test("uses authenticated DELETE without putting the token in the URL", async () => {
    let requestedURL = "";
    let requestedInit: RequestInit | undefined;

    await revokeShareSession({
      code: "code12345678",
      token: "secret-token",
      baseUrl: "wss://share.example.com/",
      fetch: (async (url, init) => {
        requestedURL = String(url);
        requestedInit = init;
        return new Response(null, { status: 204 });
      }) as typeof fetch,
    });

    expect(requestedURL).toBe(
      "https://share.example.com/v2/share/sessions/code12345678",
    );
    expect(requestedURL).not.toContain("secret-token");
    expect(requestedInit?.method).toBe("DELETE");
    expect(new Headers(requestedInit?.headers).get("authorization")).toBe(
      "Bearer secret-token",
    );
  });
});
