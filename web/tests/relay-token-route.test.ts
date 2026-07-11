import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync, verify as edVerify } from "node:crypto";

import type { AuthedUser } from "../services/vms/auth";
import {
  handleRelayTokenRequest,
  type RelayTokenDeps,
} from "../app/api/relay/token/route";

// Route behavior is exercised via injected dependencies (no module mocking, so
// nothing leaks into the shared bun-test registry). A throwaway keypair signs;
// its public key verifies the minted token exactly as a relay would.
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const HEX_ID = "0123456789abcdef".repeat(4); // valid 64-hex endpoint id

function verifyJwt(token: string): {
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
    payload: JSON.parse(Buffer.from(p, "base64url").toString()),
    valid,
  };
}

function deps(over: Partial<RelayTokenDeps> = {}): RelayTokenDeps {
  return {
    verifyRequest: async () => ({ id: "user_abc" }) as unknown as AuthedUser,
    signingKey: () => privateKey,
    nowSeconds: () => 1_700_000_000,
    checkRateLimit: async () => ({ rateLimited: false }),
    ...over,
  };
}

function postReq(body?: string): Request {
  return new Request("https://cmux.dev/api/relay/token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
  });
}

beforeEach(() => {
  delete process.env.CMUX_RELAY_URLS;
  delete process.env.CMUX_RELAY_TOKEN_RATE_LIMIT_ID;
});
afterEach(() => {
  delete process.env.CMUX_RELAY_TOKEN_RATE_LIMIT_ID;
});

describe("handleRelayTokenRequest", () => {
  test("401 when unauthenticated", async () => {
    const res = await handleRelayTokenRequest(
      postReq(JSON.stringify({ endpointId: HEX_ID })),
      deps({ verifyRequest: async () => null }),
    );
    expect(res.status).toBe(401);
  });

  test("503 when the signing key is not configured", async () => {
    const res = await handleRelayTokenRequest(
      postReq(JSON.stringify({ endpointId: HEX_ID })),
      deps({ signingKey: () => null }),
    );
    expect(res.status).toBe(503);
  });

  test("200 + relay-verifiable, endpoint-bound token", async () => {
    const res = await handleRelayTokenRequest(
      postReq(JSON.stringify({ endpointId: HEX_ID })),
      deps(),
    );
    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      token: string;
      expiresAt: number;
      ttlSeconds: number;
      relays: string[];
    };
    expect(json.ttlSeconds).toBe(300);
    expect(json.relays.length).toBe(7);
    const { payload, valid } = verifyJwt(json.token);
    expect(valid).toBe(true);
    expect(payload.iss).toBe("cmux");
    expect(payload.aud).toBe("cmux-relay");
    expect(payload.sub).toBe("user_abc");
    expect(payload.exp).toBe(json.expiresAt);
    expect(payload.endpoint_id).toBe(HEX_ID);
  });

  test("400 when endpoint_id is missing (binding is mandatory)", async () => {
    expect((await handleRelayTokenRequest(postReq(), deps())).status).toBe(400);
    expect(
      (await handleRelayTokenRequest(postReq("{}"), deps())).status,
    ).toBe(400);
    expect(
      (
        await handleRelayTokenRequest(
          postReq(JSON.stringify({ endpointId: null })),
          deps(),
        )
      ).status,
    ).toBe(400);
  });

  test("400 on a malformed endpoint_id", async () => {
    const res = await handleRelayTokenRequest(
      postReq(JSON.stringify({ endpointId: "a".repeat(48) })),
      deps(),
    );
    expect(res.status).toBe(400);
  });

  test("400 on non-object JSON (null, array, primitive)", async () => {
    for (const body of ["null", "[1,2]", "42", '"str"']) {
      const res = await handleRelayTokenRequest(postReq(body), deps());
      expect(res.status).toBe(400);
    }
  });

  test("413 on an oversized body", async () => {
    const big = JSON.stringify({ endpointId: "a".repeat(5000) });
    const res = await handleRelayTokenRequest(postReq(big), deps());
    expect(res.status).toBe(413);
  });

  test("429 when the per-account rate limit is exhausted", async () => {
    process.env.CMUX_RELAY_TOKEN_RATE_LIMIT_ID = "relay-token";
    let keyedBy: string | undefined;
    const res = await handleRelayTokenRequest(
      postReq(JSON.stringify({ endpointId: HEX_ID })),
      deps({
        checkRateLimit: async (_id, opts) => {
          keyedBy = opts.rateLimitKey;
          return { rateLimited: true };
        },
      }),
    );
    expect(res.status).toBe(429);
    // Rate limit is keyed per account, not per IP.
    expect(keyedBy).toBe("user_abc");
  });

  test("no rate-limit call when the rule id is unset", async () => {
    let called = false;
    const res = await handleRelayTokenRequest(
      postReq(JSON.stringify({ endpointId: HEX_ID })),
      deps({
        checkRateLimit: async () => {
          called = true;
          return { rateLimited: false };
        },
      }),
    );
    expect(res.status).toBe(200);
    expect(called).toBe(false);
  });
});
