import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, verify as edVerify } from "node:crypto";

import {
  handleShareGuestToken,
  type ShareGuestTokenDeps,
} from "../app/api/share/sessions/[code]/token/route";
import {
  handleShareSessionCreate,
  type ShareSessionCreateDeps,
} from "../app/api/share/sessions/route";
import {
  generateShareCode,
  isValidShareCode,
  mintShareToken,
  SHARE_CODE_LENGTH,
  SHARE_TOKEN_AUD,
  SHARE_TOKEN_ISS,
  SHARE_TOKEN_TTL_SECONDS,
} from "../services/share/token";
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

type ShareRateLimitDeps = {
  readonly checkRateLimit: (
    id: string,
    options: { request: Request; rateLimitKey?: string },
  ) => Promise<{ rateLimited: boolean; error?: string | null }>;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
};

type SessionCreateTestDeps = ShareSessionCreateDeps & ShareRateLimitDeps;
type GuestTokenTestDeps = ShareGuestTokenDeps & ShareRateLimitDeps;

function keypair() {
  return generateKeyPairSync("ed25519");
}

function sessionCreateDeps(
  overrides: Partial<SessionCreateTestDeps> = {},
): SessionCreateTestDeps {
  return {
    verifyRequest: async () => USER,
    signingKey: () => keypair().privateKey,
    nowSeconds: () => NOW,
    generateCode: generateShareCode,
    checkRateLimit: async () => ({ rateLimited: false }),
    rateLimitRuleId: () => undefined,
    isVercel: () => false,
    ...overrides,
  };
}

function guestTokenDeps(
  overrides: Partial<GuestTokenTestDeps> = {},
): GuestTokenTestDeps {
  return {
    verifyGuestRequest: async () => USER,
    verifyNativeRequest: async () => USER,
    signingKey: () => keypair().privateKey,
    nowSeconds: () => NOW,
    checkRateLimit: async () => ({ rateLimited: false }),
    rateLimitRuleId: () => undefined,
    isVercel: () => false,
    ...overrides,
  };
}

function decodePayload(token: string): Record<string, unknown> {
  const [, payload] = token.split(".");
  return JSON.parse(Buffer.from(payload ?? "", "base64url").toString());
}

describe("share codes", () => {
  test("generates unguessable, valid codes", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 100; i += 1) {
      const code = generateShareCode();
      expect(code).toHaveLength(SHARE_CODE_LENGTH);
      expect(isValidShareCode(code)).toBe(true);
      seen.add(code);
    }
    expect(seen.size).toBe(100);
  });

  test("rejects malformed codes", () => {
    expect(isValidShareCode("")).toBe(false);
    expect(isValidShareCode("short")).toBe(false);
    expect(isValidShareCode("has spaces in it 12345")).toBe(false);
    expect(isValidShareCode("with/slash0123456789012")).toBe(false);
  });
});

describe("mintShareToken", () => {
  test("mints an EdDSA JWT the worker's claim rules accept", () => {
    const { privateKey, publicKey } = keypair();
    const { token, expiresAt } = mintShareToken({
      sub: USER.id,
      email: USER.primaryEmail ?? "",
      code: "code12345678",
      host: true,
      key: privateKey,
      nowSeconds: NOW,
    });
    expect(expiresAt).toBe(NOW + SHARE_TOKEN_TTL_SECONDS);
    const [header, payload, signature] = token.split(".");
    expect(header && payload && signature).toBeTruthy();
    const ok = edVerify(
      null,
      Buffer.from(`${header}.${payload}`),
      publicKey,
      Buffer.from(signature ?? "", "base64url"),
    );
    expect(ok).toBe(true);
    const claims = decodePayload(token);
    expect(claims.iss).toBe(SHARE_TOKEN_ISS);
    expect(claims.aud).toBe(SHARE_TOKEN_AUD);
    expect(claims.sub).toBe(USER.id);
    expect(claims.email).toBe("user@example.com");
    expect(claims.code).toBe("code12345678");
    expect(claims.host).toBe(true);
    expect(claims.exp).toBe(NOW + SHARE_TOKEN_TTL_SECONDS);
  });
});

describe("POST /api/share/sessions", () => {
  const request = () =>
    new Request("https://cmux.com/api/share/sessions", { method: "POST" });

  test("401s unauthenticated callers", async () => {
    const res = await handleShareSessionCreate(
      request(),
      sessionCreateDeps({
        verifyRequest: async () => null,
      }),
    );
    expect(res.status).toBe(401);
  });

  test("returns a typed 503 when the signing key is not configured", async () => {
    const res = await handleShareSessionCreate(
      request(),
      sessionCreateDeps({
        signingKey: () => null,
        checkRateLimit: async () => {
          throw new Error("must not check a limiter when minting is disabled");
        },
      }),
    );
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "share_not_configured" });
  });

  test("mints a host grant with code, ws URL, and share URL", async () => {
    const res = await handleShareSessionCreate(
      request(),
      sessionCreateDeps({
        generateCode: () => "fixedCode0123456789012",
      }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, string>;
    expect(body.code).toBe("fixedCode0123456789012");
    expect(body.wsUrl).toContain("/v1/share/sessions/fixedCode0123456789012/ws");
    expect(body.shareUrl).toContain("/share/fixedCode0123456789012");
    expect(decodePayload(body.token ?? "").host).toBe(true);
  });

  test("checks request-IP and account budgets before minting", async () => {
    const limit = 2;
    const checks: Array<string | undefined> = [];
    let accountChecks = 0;
    let grants = 0;
    const deps = sessionCreateDeps({
      isVercel: () => true,
      rateLimitRuleId: () => "share-session-create-test",
      checkRateLimit: async (_id, options) => {
        checks.push(options.rateLimitKey);
        if (options.rateLimitKey === USER.id) accountChecks += 1;
        return { rateLimited: accountChecks > limit };
      },
      generateCode: () => {
        grants += 1;
        return "fixedCode0123456789012";
      },
    });

    const responses: Response[] = [];
    for (let index = 0; index <= limit; index += 1) {
      responses.push(await handleShareSessionCreate(request(), deps));
    }

    expect(responses.map((response) => response.status)).toEqual([200, 200, 429]);
    expect(checks).toEqual([
      undefined,
      USER.id,
      undefined,
      USER.id,
      undefined,
      USER.id,
    ]);
    expect(grants).toBe(limit);
    expect(await responses[limit]?.json()).toEqual({ error: "rate_limited" });
    const retryAfter = Number(responses[limit]?.headers.get("retry-after"));
    expect(
      Number.isSafeInteger(retryAfter) &&
        retryAfter > 0 &&
        retryAfter <= 3_600,
    ).toBe(true);
  });

  test("fails closed on Vercel when the limiter is missing or unavailable", async () => {
    let grants = 0;
    const generateCode = () => {
      grants += 1;
      return "fixedCode0123456789012";
    };
    const missing = await handleShareSessionCreate(
      request(),
      sessionCreateDeps({
        isVercel: () => true,
        rateLimitRuleId: () => undefined,
        generateCode,
      }),
    );
    expect(missing.status).toBe(503);
    expect(await missing.json()).toEqual({ error: "rate_limit_unavailable" });

    const unavailable = await handleShareSessionCreate(
      request(),
      sessionCreateDeps({
        isVercel: () => true,
        rateLimitRuleId: () => "share-session-create-test",
        checkRateLimit: async () => {
          throw new Error("firewall unavailable");
        },
        generateCode,
      }),
    );
    expect(unavailable.status).toBe(503);
    expect(await unavailable.json()).toEqual({
      error: "rate_limit_unavailable",
    });

    const deletedRule = await handleShareSessionCreate(
      request(),
      sessionCreateDeps({
        isVercel: () => true,
        rateLimitRuleId: () => "deleted-share-rule",
        checkRateLimit: async () => ({
          rateLimited: false,
          error: "not-found",
        }),
        generateCode,
      }),
    );
    expect(deletedRule.status).toBe(503);
    expect(await deletedRule.json()).toEqual({
      error: "rate_limit_unavailable",
    });
    expect(grants).toBe(0);
  });

  test("treats a firewall blocker as a rate limit", async () => {
    const res = await handleShareSessionCreate(
      request(),
      sessionCreateDeps({
        isVercel: () => true,
        rateLimitRuleId: () => "share-session-create-test",
        checkRateLimit: async () => ({
          rateLimited: false,
          error: "blocked",
        }),
        generateCode: () => {
          throw new Error("must not mint after a blocker");
        },
      }),
    );
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
  });
});

describe("POST /api/share/sessions/[code]/token", () => {
  const request = (body?: unknown) =>
    new Request("https://cmux.com/api/share/sessions/x/token", {
      method: "POST",
      ...(body === undefined
        ? {}
        : {
          body: JSON.stringify(body),
          headers: { "content-type": "application/json" },
        }),
    });

  test("400s malformed codes before parsing the body or hitting auth", async () => {
    const invalidJson = new Request(
      "https://cmux.com/api/share/sessions/x/token",
      { method: "POST", body: "{" },
    );
    const res = await handleShareGuestToken(
      invalidJson,
      "bad code!",
      guestTokenDeps({
        verifyGuestRequest: async () => {
          throw new Error("guest auth must not be called");
        },
        verifyNativeRequest: async () => {
          throw new Error("native auth must not be called");
        },
      }),
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_code" });
  });

  test("401s unauthenticated callers", async () => {
    const res = await handleShareGuestToken(
      request(),
      "code12345678",
      guestTokenDeps({
        verifyGuestRequest: async () => null,
        verifyNativeRequest: async () => {
          throw new Error("native auth must not be called for a guest");
        },
      }),
    );
    expect(res.status).toBe(401);
  });

  test("mints a guest (host=false) token bound to the code", async () => {
    const res = await handleShareGuestToken(
      request(),
      "code12345678",
      guestTokenDeps({
        verifyNativeRequest: async () => {
          throw new Error("native auth must not be called for a guest");
        },
      }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, string>;
    const claims = decodePayload(body.token ?? "");
    expect(claims.host).toBe(false);
    expect(claims.code).toBe("code12345678");
    expect(body.wsUrl).toContain("/v1/share/sessions/code12345678/ws");
  });

  test("requires native auth for host refresh and preserves the code claim", async () => {
    const rateLimitKeys: Array<string | undefined> = [];
    const res = await handleShareGuestToken(
      request({ host: true }),
      "code12345678",
      guestTokenDeps({
        verifyGuestRequest: async () => {
          throw new Error("guest auth must not mint a host grant");
        },
        verifyNativeRequest: async () => USER,
        isVercel: () => true,
        rateLimitRuleId: () => "share-token-test",
        checkRateLimit: async (_id, options) => {
          rateLimitKeys.push(options.rateLimitKey);
          return { rateLimited: false };
        },
      }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, string>;
    const claims = decodePayload(body.token ?? "");
    expect(claims.host).toBe(true);
    expect(claims.code).toBe("code12345678");
    expect(rateLimitKeys).toEqual([undefined, `${USER.id}:code12345678`]);
  });

  test("never lets cookie-only auth mint a host token", async () => {
    let mints = 0;
    const res = await handleShareGuestToken(
      request({ host: true }),
      "code12345678",
      guestTokenDeps({
        verifyGuestRequest: async () => USER,
        verifyNativeRequest: async () => null,
        nowSeconds: () => {
          mints += 1;
          return NOW;
        },
      }),
    );
    expect(res.status).toBe(401);
    expect(mints).toBe(0);
  });

  test("treats non-boolean host input as a cookie-authenticated guest", async () => {
    const res = await handleShareGuestToken(
      request({ host: "true" }),
      "code12345678",
      guestTokenDeps({
        verifyGuestRequest: async () => USER,
        verifyNativeRequest: async () => {
          throw new Error("non-boolean host must not select native auth");
        },
      }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, string>;
    expect(decodePayload(body.token ?? "").host).toBe(false);
  });

  test("bounds and validates the JSON body before auth", async () => {
    const authMustNotRun = guestTokenDeps({
      verifyGuestRequest: async () => {
        throw new Error("guest auth must not be called");
      },
      verifyNativeRequest: async () => {
        throw new Error("native auth must not be called");
      },
    });
    const invalid = await handleShareGuestToken(
      new Request("https://cmux.com/api/share/sessions/x/token", {
        method: "POST",
        body: "{",
      }),
      "code12345678",
      authMustNotRun,
    );
    expect(invalid.status).toBe(400);
    expect(await invalid.json()).toEqual({ error: "invalid_json" });

    const oversized = await handleShareGuestToken(
      request({ padding: "x".repeat(1_024) }),
      "code12345678",
      authMustNotRun,
    );
    expect(oversized.status).toBe(413);
    expect(await oversized.json()).toEqual({ error: "request_too_large" });
  });

  test("returns a typed 503 when the signing key is not configured", async () => {
    const res = await handleShareGuestToken(
      request(),
      "code12345678",
      guestTokenDeps({ signingKey: () => null }),
    );
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "share_not_configured" });
  });

  test("checks request-IP and account+code budgets before minting", async () => {
    const limit = 2;
    const checks: Array<string | undefined> = [];
    let ipChecks = 0;
    let mints = 0;
    const deps = guestTokenDeps({
      isVercel: () => true,
      rateLimitRuleId: () => "share-guest-token-test",
      checkRateLimit: async (_id, options) => {
        checks.push(options.rateLimitKey);
        if (options.rateLimitKey === undefined) ipChecks += 1;
        return { rateLimited: ipChecks > limit };
      },
      nowSeconds: () => {
        mints += 1;
        return NOW;
      },
    });

    const responses: Response[] = [];
    for (let index = 0; index <= limit; index += 1) {
      responses.push(
        await handleShareGuestToken(request(), "code12345678", deps),
      );
    }

    expect(responses.map((response) => response.status)).toEqual([200, 200, 429]);
    expect(checks).toEqual([
      undefined,
      `${USER.id}:code12345678`,
      undefined,
      `${USER.id}:code12345678`,
      undefined,
    ]);
    expect(mints).toBe(limit);
    expect(await responses[limit]?.json()).toEqual({ error: "rate_limited" });
    const retryAfter = Number(responses[limit]?.headers.get("retry-after"));
    expect(
      Number.isSafeInteger(retryAfter) &&
        retryAfter > 0 &&
        retryAfter <= 3_600,
    ).toBe(true);
  });
});
