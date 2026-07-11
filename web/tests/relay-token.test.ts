import { beforeEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync, verify as edVerify } from "node:crypto";

import {
  RELAY_TOKEN_TTL_SECONDS,
  isValidEndpointId,
  mintRelayToken,
  relaySigningKey,
  relayUrls,
} from "../services/relay/token";

// Pure unit tests: no route/auth mocking, so nothing leaks into the shared
// bun-test module registry. A throwaway keypair stands in for the fleet — the
// public key verifies the minted token exactly as a relay would.
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const privatePem = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

function verifyJwt(token: string): {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
  valid: boolean;
} {
  const [h, p, s] = token.split(".");
  const valid = edVerify(
    null,
    Buffer.from(`${h}.${p}`),
    publicKey,
    Buffer.from(s, "base64url"),
  );
  return {
    header: JSON.parse(Buffer.from(h, "base64url").toString()),
    payload: JSON.parse(Buffer.from(p, "base64url").toString()),
    valid,
  };
}

beforeEach(() => {
  process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM = privatePem;
  delete process.env.CMUX_RELAY_URLS;
});

describe("mintRelayToken", () => {
  test("mints an EdDSA JWT that verifies against the matching public key", () => {
    const key = relaySigningKey();
    expect(key).not.toBeNull();
    const now = 1_700_000_000;
    const { token, expiresAt } = mintRelayToken({
      sub: "user_abc",
      key: key!,
      nowSeconds: now,
    });
    const { header, payload, valid } = verifyJwt(token);
    // Verifies against the PUBLIC key -> the relay would accept it.
    expect(valid).toBe(true);
    expect(header.alg).toBe("EdDSA");
    expect(header.typ).toBe("JWT");
    expect(payload.iss).toBe("cmux");
    expect(payload.aud).toBe("cmux-relay");
    expect(payload.sub).toBe("user_abc");
    expect(payload.iat).toBe(now);
    expect(payload.exp).toBe(now + RELAY_TOKEN_TTL_SECONDS);
    expect(expiresAt).toBe(now + RELAY_TOKEN_TTL_SECONDS);
    expect(payload.endpoint_id).toBeUndefined();
  });

  test("binds and lowercases endpoint_id when provided", () => {
    const key = relaySigningKey()!;
    const { token } = mintRelayToken({
      sub: "user_1",
      endpointId: "ABCdef0123456789".repeat(3), // 48 hex-ish chars
      key,
      nowSeconds: 1_700_000_000,
    });
    const { payload, valid } = verifyJwt(token);
    expect(valid).toBe(true);
    expect(payload.endpoint_id).toBe("abcdef0123456789".repeat(3));
  });

  test("a token signed by a different key does NOT verify", () => {
    const key = relaySigningKey()!;
    const { token } = mintRelayToken({
      sub: "user_1",
      key,
      nowSeconds: 1_700_000_000,
    });
    const other = generateKeyPairSync("ed25519").publicKey;
    const [h, p, s] = token.split(".");
    const valid = edVerify(
      null,
      Buffer.from(`${h}.${p}`),
      other,
      Buffer.from(s, "base64url"),
    );
    expect(valid).toBe(false);
  });
});

describe("relaySigningKey", () => {
  test("returns null when the PEM is unset or malformed", () => {
    delete process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM;
    expect(relaySigningKey()).toBeNull();
    process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM = "not a pem";
    expect(relaySigningKey()).toBeNull();
  });
});

describe("isValidEndpointId", () => {
  test("accepts hex (64) and z-base-32-shaped (52) ids", () => {
    expect(isValidEndpointId("a".repeat(64))).toBe(true);
    expect(isValidEndpointId("ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkm")).toBe(
      true,
    );
  });
  test("rejects too-short, too-long, and non-alphanumeric ids", () => {
    expect(isValidEndpointId("short")).toBe(false);
    expect(isValidEndpointId("a".repeat(200))).toBe(false);
    expect(isValidEndpointId("has spaces and !!")).toBe(false);
  });
});

describe("relayUrls", () => {
  test("defaults to the 7-region fleet", () => {
    const urls = relayUrls();
    expect(urls).toContain("https://usw1.relay.cmux.dev");
    expect(urls).toContain("https://use4.relay.cmux.dev");
    expect(urls.length).toBe(7);
  });
  test("honors the CMUX_RELAY_URLS override", () => {
    process.env.CMUX_RELAY_URLS = "https://a.example.com, https://b.example.com";
    expect(relayUrls()).toEqual([
      "https://a.example.com",
      "https://b.example.com",
    ]);
  });
});
