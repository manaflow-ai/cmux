// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import {
  parseJwt,
  SHARE_JWT_AUDIENCE,
  SHARE_JWT_ISSUER,
  validateClaims,
  verifyShareToken,
} from "../src/jwt";

const NOW = 1_700_000_000_000;

function b64url(bytes: Uint8Array): string {
  let raw = "";
  for (const b of bytes) raw += String.fromCharCode(b);
  return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function claims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iss: SHARE_JWT_ISSUER,
    aud: SHARE_JWT_AUDIENCE,
    sub: "u-1",
    email: "a@b.c",
    code: "code123",
    host: false,
    exp: Math.floor(NOW / 1000) + 300,
    ...overrides,
  };
}

async function mint(
  payload: Record<string, unknown>,
  privateKey: CryptoKey,
): Promise<string> {
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: "EdDSA", typ: "JWT" })));
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign(
    { name: "Ed25519" },
    privateKey,
    enc.encode(`${header}.${body}`),
  );
  return `${header}.${body}.${b64url(new Uint8Array(signature))}`;
}

async function keypairPem(): Promise<{ privateKey: CryptoKey; publicPem: string }> {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ])) as unknown as CryptoKeyPair;
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey));
  let raw = "";
  for (const b of spki) raw += String.fromCharCode(b);
  const base64 = btoa(raw);
  const lines = base64.match(/.{1,64}/g) ?? [];
  const publicPem = `-----BEGIN PUBLIC KEY-----\n${lines.join("\n")}\n-----END PUBLIC KEY-----\n`;
  return { privateKey: pair.privateKey, publicPem };
}

describe("claim validation (pure)", () => {
  it("accepts a well-formed payload", () => {
    const result = validateClaims(claims({ host: true }), "code123", NOW);
    expect(result).toEqual({
      sub: "u-1",
      email: "a@b.c",
      code: "code123",
      host: true,
      create: false,
    });
  });

  it("create claim must be literal true", () => {
    expect(validateClaims(claims({ create: true }), "code123", NOW)?.create).toBe(true);
    expect(validateClaims(claims({ create: "true" }), "code123", NOW)?.create).toBe(false);
  });

  it.each([
    ["wrong issuer", claims({ iss: "other" })],
    ["wrong audience", claims({ aud: "cmux-relay" })],
    ["expired", claims({ exp: Math.floor(NOW / 1000) - 1 })],
    ["non-finite expiry", claims({ exp: Number.POSITIVE_INFINITY })],
    ["missing sub", claims({ sub: "" })],
    ["oversized sub", claims({ sub: "u".repeat(300) })],
    ["newline email", claims({ email: "a@example.com\nforged@example.com" })],
    ["C1 control in email", claims({ email: "a@example.com\u0085forged@example.com" })],
    ["C1 control in sub", claims({ sub: "u-1\u009fhidden" })],
    ["code mismatch", claims({ code: "other" })],
  ])("rejects %s", (_label, payload) => {
    expect(validateClaims(payload, "code123", NOW)).toBeNull();
  });

  it("host claim must be literal true", () => {
    expect(validateClaims(claims({ host: "true" }), "code123", NOW)?.host).toBe(false);
  });
});

describe("parseJwt", () => {
  it("rejects structurally invalid tokens", () => {
    expect(parseJwt("nope")).toBeNull();
    expect(parseJwt("a.b")).toBeNull();
    expect(parseJwt("!!.!!.!!")).toBeNull();
  });

  it("rejects non-EdDSA algs", async () => {
    const enc = new TextEncoder();
    const header = b64url(enc.encode(JSON.stringify({ alg: "none" })));
    const body = b64url(enc.encode(JSON.stringify(claims())));
    expect(parseJwt(`${header}.${body}.${b64url(new Uint8Array([1]))}`)).toBeNull();
  });
});

describe("verifyShareToken (signature + claims)", () => {
  it("accepts a token signed by the paired private key", async () => {
    const { privateKey, publicPem } = await keypairPem();
    const token = await mint(claims(), privateKey);
    const result = await verifyShareToken(token, "code123", publicPem, NOW);
    expect(result?.sub).toBe("u-1");
    expect(result?.host).toBe(false);
  });

  it("rejects a token signed by a different key", async () => {
    const { privateKey } = await keypairPem();
    const { publicPem: otherPem } = await keypairPem();
    const token = await mint(claims(), privateKey);
    expect(await verifyShareToken(token, "code123", otherPem, NOW)).toBeNull();
  });

  it("rejects a tampered payload", async () => {
    const { privateKey, publicPem } = await keypairPem();
    const token = await mint(claims(), privateKey);
    const parts = token.split(".");
    const forged = b64url(new TextEncoder().encode(JSON.stringify(claims({ host: true }))));
    const tampered = `${parts[0]}.${forged}.${parts[2]}`;
    expect(await verifyShareToken(tampered, "code123", publicPem, NOW)).toBeNull();
  });

  it("rejects a valid token presented for another code", async () => {
    const { privateKey, publicPem } = await keypairPem();
    const token = await mint(claims(), privateKey);
    expect(await verifyShareToken(token, "otherCode", publicPem, NOW)).toBeNull();
  });

  it("rejects garbage public keys without throwing", async () => {
    const { privateKey } = await keypairPem();
    const token = await mint(claims(), privateKey);
    expect(await verifyShareToken(token, "code123", "not a pem", NOW)).toBeNull();
  });
});
