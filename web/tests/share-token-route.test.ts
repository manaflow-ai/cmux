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
    verifyRequest: async () => USER,
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
  const request = () => new Request("https://cmux.com/api/share/sessions", { method: "POST" });

  test("401s unauthenticated callers", async () => {
    const res = await handleShareSessionCreate(request(), sessionCreateDeps({
      verifyRequest: async () => null,
    }));
    expect(res.status).toBe(401);
  });

  test("503s when the signing key is not configured", async () => {
    const res = await handleShareSessionCreate(request(), sessionCreateDeps({
      signingKey: () => null,
    }));
    expect(res.status).toBe(503);
  });

  test("mints a host grant with code, ws URL, and share URL", async () => {
    const res = await handleShareSessionCreate(request(), sessionCreateDeps({
      generateCode: () => "fixedCode0123456789012",
    }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, string>;
    expect(body.code).toBe("fixedCode0123456789012");
    expect(body.wsUrl).toContain("/v1/share/sessions/fixedCode0123456789012/ws");
    expect(body.shareUrl).toContain("/share/fixedCode0123456789012");
    expect(decodePayload(body.token ?? "").host).toBe(true);
  });

  test("allows N session creates and rejects N+1 before minting another grant", async () => {
    const limit = 2;
    let checks = 0;
    let grants = 0;
    const deps = sessionCreateDeps({
      isVercel: () => true,
      rateLimitRuleId: () => "share-session-create-test",
      checkRateLimit: async () => {
        checks += 1;
        return { rateLimited: checks > limit };
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
    expect(checks).toBe(limit + 1);
    expect(grants).toBe(limit);
    expect(await responses[limit]?.json()).toEqual({ error: "rate_limited" });
    const retryAfter = Number(responses[limit]?.headers.get("retry-after"));
    expect(Number.isSafeInteger(retryAfter) && retryAfter > 0).toBe(true);
  });
});

describe("POST /api/share/sessions/[code]/token", () => {
  const request = () =>
    new Request("https://cmux.com/api/share/sessions/x/token", { method: "POST" });

  test("400s malformed codes without hitting auth", async () => {
    const res = await handleShareGuestToken(request(), "bad code!", guestTokenDeps({
      verifyRequest: async () => {
        throw new Error("must not be called");
      },
    }));
    expect(res.status).toBe(400);
  });

  test("401s unauthenticated callers", async () => {
    const res = await handleShareGuestToken(request(), "code12345678", guestTokenDeps({
      verifyRequest: async () => null,
    }));
    expect(res.status).toBe(401);
  });

  test("mints a guest (host=false) token bound to the code", async () => {
    const res = await handleShareGuestToken(
      request(),
      "code12345678",
      guestTokenDeps(),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, string>;
    const claims = decodePayload(body.token ?? "");
    expect(claims.host).toBe(false);
    expect(claims.code).toBe("code12345678");
    expect(body.wsUrl).toContain("/v1/share/sessions/code12345678/ws");
  });

  test("allows N token grants and rejects N+1 before minting another token", async () => {
    const limit = 2;
    let checks = 0;
    let mints = 0;
    const deps = guestTokenDeps({
      isVercel: () => true,
      rateLimitRuleId: () => "share-guest-token-test",
      checkRateLimit: async () => {
        checks += 1;
        return { rateLimited: checks > limit };
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
    expect(checks).toBe(limit + 1);
    expect(mints).toBe(limit);
    expect(await responses[limit]?.json()).toEqual({ error: "rate_limited" });
    const retryAfter = Number(responses[limit]?.headers.get("retry-after"));
    expect(Number.isSafeInteger(retryAfter) && retryAfter > 0).toBe(true);
  });
});
