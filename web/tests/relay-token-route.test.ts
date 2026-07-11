import { beforeEach, describe, expect, mock, test } from "bun:test";
import { generateKeyPairSync, verify as edVerify } from "node:crypto";

// Self-contained mocks so this route can be tested in isolation without pulling
// the DB/Stack/telemetry graph behind services/vms/auth + routeHelpers. Both
// stubs mirror the real signatures the route depends on.
let currentUser: { id: string } | null = null;

mock.module("../services/vms/auth", () => ({
  verifyRequest: async () => currentUser,
  unauthorized: () =>
    new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "content-type": "application/json" },
    }),
}));

mock.module("../services/vms/routeHelpers", () => ({
  jsonResponse: (data: unknown, status = 200) =>
    new Response(JSON.stringify(data), {
      status,
      headers: { "content-type": "application/json" },
    }),
}));

// A throwaway Ed25519 keypair. The private PEM feeds the route; the public key
// stands in for a relay verifying the minted token offline.
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const privatePem = privateKey.export({ type: "pkcs8", format: "pem" }) as string;

const { POST } = await import("../app/api/relay/token/route");

function postReq(body?: unknown): Request {
  return new Request("https://cmux.dev/api/relay/token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// Verify the compact JWT exactly as the relay would: Ed25519 over `header.payload`.
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
  currentUser = null;
  process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM = privatePem;
  delete process.env.CMUX_RELAY_URLS;
});

describe("POST /api/relay/token", () => {
  test("401 when unauthenticated", async () => {
    currentUser = null;
    const res = await POST(postReq());
    expect(res.status).toBe(401);
  });

  test("mints a relay-verifiable EdDSA JWT for a signed-in user", async () => {
    currentUser = { id: "user_abc" };
    const res = await POST(postReq());
    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      token: string;
      expiresAt: number;
      ttlSeconds: number;
      relays: string[];
    };
    expect(json.relays).toContain("https://usw1.relay.cmux.dev");
    expect(json.relays).toContain("https://use4.relay.cmux.dev");
    expect(json.ttlSeconds).toBe(300);

    const { header, payload, valid } = verifyJwt(json.token);
    // Signature verifies against the PUBLIC key -> the relay would accept it.
    expect(valid).toBe(true);
    expect(header.alg).toBe("EdDSA");
    expect(header.typ).toBe("JWT");
    expect(payload.iss).toBe("cmux");
    expect(payload.aud).toBe("cmux-relay");
    expect(payload.sub).toBe("user_abc");
    expect((payload.exp as number) - (payload.iat as number)).toBe(300);
    expect(payload.exp).toBe(json.expiresAt);
    expect(payload.endpoint_id).toBeUndefined();
  });

  test("binds endpoint_id when provided", async () => {
    currentUser = { id: "user_123" };
    const eid = "y".repeat(52); // z-base-32-shaped endpoint id
    const res = await POST(postReq({ endpointId: eid }));
    expect(res.status).toBe(200);
    const { payload, valid } = verifyJwt(
      ((await res.json()) as { token: string }).token,
    );
    expect(valid).toBe(true);
    expect(payload.endpoint_id).toBe(eid);
  });

  test("400 on malformed endpoint_id", async () => {
    currentUser = { id: "user_123" };
    const res = await POST(postReq({ endpointId: "not a valid id!!" }));
    expect(res.status).toBe(400);
  });

  test("honors CMUX_RELAY_URLS override", async () => {
    currentUser = { id: "user_123" };
    process.env.CMUX_RELAY_URLS =
      "https://a.example.com, https://b.example.com";
    const res = await POST(postReq());
    const json = (await res.json()) as { relays: string[] };
    expect(json.relays).toEqual([
      "https://a.example.com",
      "https://b.example.com",
    ]);
  });

  test("503 when the signing key is not configured", async () => {
    currentUser = { id: "user_123" };
    delete process.env.CMUX_RELAY_JWT_PRIVATE_KEY_PEM;
    const res = await POST(postReq());
    expect(res.status).toBe(503);
  });
});
