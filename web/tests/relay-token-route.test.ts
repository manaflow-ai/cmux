import { beforeEach, describe, expect, test } from "bun:test";
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
});

describe("handleRelayTokenRequest", () => {
  test("401 when unauthenticated", async () => {
    const res = await handleRelayTokenRequest(
      postReq(),
      deps({ verifyRequest: async () => null }),
    );
    expect(res.status).toBe(401);
  });

  test("503 when the signing key is not configured", async () => {
    const res = await handleRelayTokenRequest(
      postReq(),
      deps({ signingKey: () => null }),
    );
    expect(res.status).toBe(503);
  });

  test("200 + relay-verifiable token for an empty body", async () => {
    const res = await handleRelayTokenRequest(postReq(), deps());
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
    expect(payload.endpoint_id).toBeUndefined();
  });

  test("binds endpoint_id when provided", async () => {
    const eid = "a".repeat(52);
    const res = await handleRelayTokenRequest(
      postReq(JSON.stringify({ endpointId: eid })),
      deps(),
    );
    expect(res.status).toBe(200);
    const { payload, valid } = verifyJwt(
      ((await res.json()) as { token: string }).token,
    );
    expect(valid).toBe(true);
    expect(payload.endpoint_id).toBe(eid);
  });

  test("400 on malformed endpoint_id", async () => {
    const res = await handleRelayTokenRequest(
      postReq(JSON.stringify({ endpointId: "bad id !!" })),
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
});
