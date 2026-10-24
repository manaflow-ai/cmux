import { afterEach, describe, expect, it, vi } from "vitest";
import { resetAppleKeyCache, verifyAppleIdentityToken } from "../src/apple";
import { base64UrlEncode, sha256Hex, utf8 } from "../src/crypto";

async function setup() {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  const fetchMock = vi.fn(async () => new Response(JSON.stringify({ keys: [{ ...jwk, kid: "k1", alg: "RS256", use: "sig" }] })));
  vi.stubGlobal("fetch", fetchMock);
  resetAppleKeyCache();
  const sign = async (payload: Record<string, unknown>, kid = "k1") => {
    const input = `${base64UrlEncode(utf8(JSON.stringify({ alg: "RS256", kid })))}.${base64UrlEncode(utf8(JSON.stringify(payload)))}`;
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, utf8(input));
    return `${input}.${base64UrlEncode(new Uint8Array(sig))}`;
  };
  return { sign, fetchMock };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("apple identity tokens", () => {
  it("verifies a valid token and enforces aud, nonce and exp", async () => {
    const { sign } = await setup();
    const now = 1_000_000;
    const base = {
      iss: "https://appleid.apple.com",
      aud: "dev.cmux.next.mobile",
      sub: "apple-sub",
      exp: now + 600,
      nonce: await sha256Hex("raw"),
      email: "A@Example.com",
      email_verified: "true",
    };
    const id = await verifyAppleIdentityToken(await sign(base), "raw", ["dev.cmux.next.mobile"], now);
    expect(id).toEqual({ sub: "apple-sub", email: "a@example.com", emailVerified: true });

    await expect(verifyAppleIdentityToken(await sign(base), "other", ["dev.cmux.next.mobile"], now)).rejects.toThrow("bad nonce");
    await expect(verifyAppleIdentityToken(await sign({ ...base, aud: "x" }), "raw", ["dev.cmux.next.mobile"], now)).rejects.toThrow("bad audience");
    await expect(verifyAppleIdentityToken(await sign({ ...base, exp: now - 1 }), "raw", ["dev.cmux.next.mobile"], now)).rejects.toThrow("expired");
    await expect(verifyAppleIdentityToken(await sign({ ...base, iss: "evil" }), "raw", ["dev.cmux.next.mobile"], now)).rejects.toThrow("bad issuer");
    const t = await sign(base);
    await expect(verifyAppleIdentityToken(`${t.slice(0, -4)}AAAA`, "raw", ["dev.cmux.next.mobile"], now)).rejects.toThrow();
  });

  it("refetches the JWKS for an unknown kid at most once per minute", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-12T10:00:00Z"));
    const { sign, fetchMock } = await setup();
    const now = Math.floor(Date.now() / 1000);
    const token = await sign({ iss: "https://appleid.apple.com", aud: "a", sub: "s", exp: now + 600 }, "unknown");
    for (let i = 0; i < 5; i++) await expect(verifyAppleIdentityToken(token, "raw", ["a"], now)).rejects.toThrow("unknown key");
    // The initial fetch is fresh, so no forced refetch happens within the minute.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    vi.setSystemTime(new Date("2026-10-12T10:01:01Z"));
    await expect(verifyAppleIdentityToken(token, "raw", ["a"], now)).rejects.toThrow("unknown key");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    for (let i = 0; i < 5; i++) await expect(verifyAppleIdentityToken(token, "raw", ["a"], now)).rejects.toThrow("unknown key");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
