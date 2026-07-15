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

// A valid 64-hex iroh EndpointId and a valid 52-char RFC 4648 base32 one
// (A-Z2-7; "a" == 0 decodes to a 32-byte value).
const HEX_ID = "0123456789abcdef".repeat(4);
const BASE32_ID = "a".repeat(52);

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
      endpointId: HEX_ID,
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
    // endpoint_id is always bound.
    expect(payload.endpoint_id).toBe(HEX_ID);
  });

  test("lowercases the bound endpoint_id", () => {
    const key = relaySigningKey()!;
    const { token } = mintRelayToken({
      sub: "user_1",
      endpointId: HEX_ID.toUpperCase(),
      key,
      nowSeconds: 1_700_000_000,
    });
    const { payload } = verifyJwt(token);
    expect(payload.endpoint_id).toBe(HEX_ID);
  });

  test("a token signed by a different key does NOT verify", () => {
    const key = relaySigningKey()!;
    const { token } = mintRelayToken({
      sub: "user_1",
      endpointId: BASE32_ID,
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

  test("returns null for a non-Ed25519 key (RSA)", () => {
    const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 });
    process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM = rsa.privateKey.export({
      type: "pkcs8",
      format: "pem",
    }) as string;
    expect(relaySigningKey()).toBeNull();
  });
});

describe("isValidEndpointId", () => {
  test("accepts exact 64-hex and 52-char RFC 4648 base32 (any case)", () => {
    expect(isValidEndpointId(HEX_ID)).toBe(true);
    expect(isValidEndpointId(HEX_ID.toUpperCase())).toBe(true);
    expect(isValidEndpointId(BASE32_ID)).toBe(true);
    expect(isValidEndpointId(BASE32_ID.toUpperCase())).toBe(true);
  });
  test("rejects wrong-length or out-of-alphabet ids", () => {
    expect(isValidEndpointId("a".repeat(48))).toBe(false); // wrong length
    expect(isValidEndpointId("a".repeat(63))).toBe(false); // 63 != 64
    expect(isValidEndpointId(`${HEX_ID}00`)).toBe(false); // 66 hex
    expect(isValidEndpointId("g".repeat(64))).toBe(false); // 'g' not hex
    // '1'/'8' are z-base-32 but NOT RFC 4648 base32, so must be rejected.
    expect(isValidEndpointId("1".repeat(52))).toBe(false);
    expect(isValidEndpointId("8".repeat(52))).toBe(false);
    // Non-canonical final symbol (non-zero trailing bits) — iroh's decoder
    // rejects it, so we must too (final char must be 'a' or 'q').
    expect(isValidEndpointId("a".repeat(51) + "b")).toBe(false);
    expect(isValidEndpointId("a".repeat(51) + "q")).toBe(true);
    expect(isValidEndpointId("has spaces!!")).toBe(false);
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
