import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, verify as edVerify } from "node:crypto";

import { handleShareGuestToken } from "../app/api/share/sessions/[code]/token/route";
import { handleShareSessionCreate } from "../app/api/share/sessions/route";
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

function keypair() {
  return generateKeyPairSync("ed25519");
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
    const res = await handleShareSessionCreate(request(), {
      verifyRequest: async () => null,
      signingKey: () => keypair().privateKey,
      nowSeconds: () => NOW,
      generateCode: generateShareCode,
    });
    expect(res.status).toBe(401);
  });

  test("503s when the signing key is not configured", async () => {
    const res = await handleShareSessionCreate(request(), {
      verifyRequest: async () => USER,
      signingKey: () => null,
      nowSeconds: () => NOW,
      generateCode: generateShareCode,
    });
    expect(res.status).toBe(503);
  });

  test("mints a host grant with code, ws URL, and share URL", async () => {
    const res = await handleShareSessionCreate(request(), {
      verifyRequest: async () => USER,
      signingKey: () => keypair().privateKey,
      nowSeconds: () => NOW,
      generateCode: () => "fixedCode0123456789012",
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, string>;
    expect(body.code).toBe("fixedCode0123456789012");
    expect(body.wsUrl).toContain("/v1/share/sessions/fixedCode0123456789012/ws");
    expect(body.shareUrl).toContain("/share/fixedCode0123456789012");
    expect(decodePayload(body.token ?? "").host).toBe(true);
  });
});

describe("POST /api/share/sessions/[code]/token", () => {
  const request = () =>
    new Request("https://cmux.com/api/share/sessions/x/token", { method: "POST" });

  test("400s malformed codes without hitting auth", async () => {
    const res = await handleShareGuestToken(request(), "bad code!", {
      verifyRequest: async () => {
        throw new Error("must not be called");
      },
      signingKey: () => null,
      nowSeconds: () => NOW,
    });
    expect(res.status).toBe(400);
  });

  test("401s unauthenticated callers", async () => {
    const res = await handleShareGuestToken(request(), "code12345678", {
      verifyRequest: async () => null,
      signingKey: () => keypair().privateKey,
      nowSeconds: () => NOW,
    });
    expect(res.status).toBe(401);
  });

  test("mints a guest (host=false) token bound to the code", async () => {
    const res = await handleShareGuestToken(request(), "code12345678", {
      verifyRequest: async () => USER,
      signingKey: () => keypair().privateKey,
      nowSeconds: () => NOW,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, string>;
    const claims = decodePayload(body.token ?? "");
    expect(claims.host).toBe(false);
    expect(claims.code).toBe("code12345678");
    expect(body.wsUrl).toContain("/v1/share/sessions/code12345678/ws");
  });
});
