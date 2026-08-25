import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";

import {
  handleRelayAllowRequest,
  type RelayAllowDeps,
} from "../app/api/relay/allow/route";
import {
  RELAY_ALLOW_MAX_CONCURRENT_ADMISSIONS,
  RELAY_ALLOW_SIGNATURE_HEADER,
  RelayAllowAdmissionSaturatedError,
  parseRelayAllowSecret,
  relayAllowSignature,
  verifyRelayAllowSignature,
  withRelayAllowAdmissionSlot,
} from "../services/relay/allow";

// Pure route tests: deps injection only, nothing leaks into the shared
// bun-test module registry, no database.
const SECRET = randomBytes(32);
const SECRET_B64 = SECRET.toString("base64");
const ACTIVE_ID = "0123456789abcdef".repeat(4);
const REVOKED_ID = "f".repeat(64);
const UNKNOWN_ID = "e".repeat(64);
const EMPTY_BODY_SIGNATURE = relayAllowSignature(SECRET, new Uint8Array());

function deps(overrides: Partial<RelayAllowDeps> = {}): RelayAllowDeps {
  return {
    secretBase64: () => SECRET_B64,
    // The production impl treats revoked and unknown identically (deny); the
    // fake keeps them distinct so both paths are pinned here.
    admission: async (endpointId) => endpointId === ACTIVE_ID ? "allow" : "deny",
    ...overrides,
  };
}

/** The exact shape iroh-relay 1.0.3 sends: empty body, X-Iroh-NodeId header,
 * static bearer token (configured as the HMAC of the empty body). */
function relayShapedRequest(
  endpointId: string,
  bearer: string = EMPTY_BODY_SIGNATURE,
): Request {
  return new Request("https://cmux.dev/api/relay/allow", {
    method: "POST",
    headers: {
      "X-Iroh-NodeId": endpointId,
      authorization: `Bearer ${bearer}`,
    },
  });
}

function jsonShapedRequest(
  body: unknown,
  signature?: string,
): Request {
  const text = JSON.stringify(body);
  return new Request("https://cmux.dev/api/relay/allow", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      [RELAY_ALLOW_SIGNATURE_HEADER]:
        signature ?? relayAllowSignature(SECRET, Buffer.from(text, "utf8")),
    },
    body: text,
  });
}

describe("POST /api/relay/allow", () => {
  test("admits an active binding with the exact `true` text contract", async () => {
    const response = await handleRelayAllowRequest(
      relayShapedRequest(ACTIVE_ID),
      deps(),
    );
    expect(response.status).toBe(200);
    // iroh-relay compares res.text() == "true" byte-for-byte.
    expect(await response.text()).toBe("true");
    expect(response.headers.get("content-type")).toBe("application/json");
    // Never cacheable: the endpoint identity rides a header, so a shared HTTP
    // cache would cross decisions between endpoints and outlive revocation.
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  test("denies an unknown endpoint with `false`, uncacheable", async () => {
    const response = await handleRelayAllowRequest(
      relayShapedRequest(UNKNOWN_ID),
      deps(),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("false");
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  test("denies a revoked binding", async () => {
    const response = await handleRelayAllowRequest(
      relayShapedRequest(REVOKED_ID),
      deps(),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("false");
  });

  test("accepts the JSON body form signed over the body", async () => {
    const response = await handleRelayAllowRequest(
      jsonShapedRequest({ endpointId: ACTIVE_ID }),
      deps(),
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("true");
  });

  test("lowercases a mixed-case endpoint id before admission", async () => {
    const observed: string[] = [];
    const response = await handleRelayAllowRequest(
      relayShapedRequest(ACTIVE_ID.toUpperCase()),
      deps({
        admission: async (endpointId) => {
          observed.push(endpointId);
          return "allow";
        },
      }),
    );
    expect(response.status).toBe(200);
    expect(observed).toEqual([ACTIVE_ID]);
  });

  test("401 when the signature is missing", async () => {
    const request = new Request("https://cmux.dev/api/relay/allow", {
      method: "POST",
      headers: { "X-Iroh-NodeId": ACTIVE_ID },
    });
    const response = await handleRelayAllowRequest(request, deps());
    expect(response.status).toBe(401);
  });

  test("401 when the bearer HMAC is wrong", async () => {
    const response = await handleRelayAllowRequest(
      relayShapedRequest(ACTIVE_ID, relayAllowSignature(randomBytes(32), new Uint8Array())),
      deps(),
    );
    expect(response.status).toBe(401);
  });

  test("401 when a body signature does not cover the actual body", async () => {
    // Signature valid for a DIFFERENT endpoint's body: tampering must fail.
    const response = await handleRelayAllowRequest(
      jsonShapedRequest(
        { endpointId: ACTIVE_ID },
        relayAllowSignature(
          SECRET,
          Buffer.from(JSON.stringify({ endpointId: UNKNOWN_ID }), "utf8"),
        ),
      ),
      deps(),
    );
    expect(response.status).toBe(401);
  });

  test("503 when the shared secret is unset (fail closed)", async () => {
    const response = await handleRelayAllowRequest(
      relayShapedRequest(ACTIVE_ID),
      deps({ secretBase64: () => undefined }),
    );
    expect(response.status).toBe(503);
    expect(await response.text()).not.toBe("true");
  });

  test("503 when the shared secret is malformed", async () => {
    const response = await handleRelayAllowRequest(
      relayShapedRequest(ACTIVE_ID),
      deps({ secretBase64: () => "not-base64!!" }),
    );
    expect(response.status).toBe(503);
  });

  test("400 on a malformed endpoint id header", async () => {
    const response = await handleRelayAllowRequest(
      relayShapedRequest("zz".repeat(32)),
      deps(),
    );
    expect(response.status).toBe(400);
    expect(await response.text()).not.toBe("true");
  });

  test("400 when no endpoint id is present anywhere", async () => {
    const request = new Request("https://cmux.dev/api/relay/allow", {
      method: "POST",
      headers: { authorization: `Bearer ${EMPTY_BODY_SIGNATURE}` },
    });
    const response = await handleRelayAllowRequest(request, deps());
    expect(response.status).toBe(400);
  });

  test("503 within the deadline when the admission lookup stalls", async () => {
    const startedAt = Date.now();
    const response = await handleRelayAllowRequest(
      relayShapedRequest(ACTIVE_ID),
      deps({
        // Never settles: a stalled database query must not hold the relay's
        // access check open. The deadline fails closed.
        admission: () => new Promise<never>(() => {}),
        admissionTimeoutMs: 25,
      }),
    );
    expect(response.status).toBe(503);
    expect(await response.text()).not.toBe("true");
    expect(Date.now() - startedAt).toBeLessThan(1_000);
  });

  test("408 within the bound when an unauthenticated body stalls (slowloris)", async () => {
    const startedAt = Date.now();
    const response = await handleRelayAllowRequest(
      new Request("https://cmux.dev/api/relay/allow", {
        method: "POST",
        headers: { "content-type": "application/json" },
        // A stream that trickles one byte and never finishes.
        body: new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new Uint8Array([0x7b]));
          },
        }),
        // @ts-expect-error duplex is required for stream bodies but absent
        // from the lib.dom Request typings.
        duplex: "half",
      }),
      deps({ bodyReadTimeoutMs: 25 }),
    );
    expect(response.status).toBe(408);
    expect(await response.text()).not.toBe("true");
    expect(Date.now() - startedAt).toBeLessThan(1_000);
  });

  test("503 (deny at the relay) when the admission lookup throws", async () => {
    const response = await handleRelayAllowRequest(
      relayShapedRequest(ACTIVE_ID),
      deps({
        admission: async () => {
          throw new Error("database unreachable");
        },
      }),
    );
    expect(response.status).toBe(503);
  });
});

describe("relay allow admission concurrency cap", () => {
  test("bounds retained work and rejects immediately when saturated", async () => {
    const releases: (() => void)[] = [];
    const held = Array.from(
      { length: RELAY_ALLOW_MAX_CONCURRENT_ADMISSIONS },
      () =>
        withRelayAllowAdmissionSlot(
          () =>
            new Promise<"allow">((resolve) => {
              releases.push(() => resolve("allow"));
            }),
        ),
    );
    // Every slot is held by a pending lookup: the next admission must fail
    // fast (the route's fail-closed 503) instead of queueing more work.
    await expect(withRelayAllowAdmissionSlot(async () => "allow")).rejects.toThrow(
      RelayAllowAdmissionSaturatedError,
    );
    for (const release of releases) release();
    await Promise.all(held);
    // Slots free once lookups settle.
    expect(await withRelayAllowAdmissionSlot(async () => "allow")).toBe("allow");
  });

  test("a slot held by a rejecting operation is released at settlement", async () => {
    await expect(
      withRelayAllowAdmissionSlot(async () => {
        throw new Error("lookup failed");
      }),
    ).rejects.toThrow("lookup failed");
    expect(await withRelayAllowAdmissionSlot(async () => "allow")).toBe("allow");
  });
});

describe("relay allow HMAC helpers", () => {
  test("parseRelayAllowSecret enforces canonical base64 and 32-256 bytes", () => {
    expect(parseRelayAllowSecret(undefined)).toBeNull();
    expect(parseRelayAllowSecret("")).toBeNull();
    expect(parseRelayAllowSecret(randomBytes(16).toString("base64"))).toBeNull();
    const canonical = parseRelayAllowSecret(SECRET_B64);
    expect(canonical?.equals(SECRET)).toBe(true);
    // Unpadded canonical form is accepted too.
    expect(
      parseRelayAllowSecret(SECRET_B64.replace(/=+$/, ""))?.equals(SECRET),
    ).toBe(true);
  });

  test("verifyRelayAllowSignature rejects wrong length and wrong key", () => {
    const body = Buffer.from("{}", "utf8");
    const good = relayAllowSignature(SECRET, body);
    expect(verifyRelayAllowSignature(SECRET, body, good)).toBe(true);
    expect(verifyRelayAllowSignature(SECRET, body, good.slice(0, 42))).toBe(false);
    expect(verifyRelayAllowSignature(SECRET, body, `${good}a`)).toBe(false);
    expect(
      verifyRelayAllowSignature(randomBytes(32), body, good),
    ).toBe(false);
  });
});
