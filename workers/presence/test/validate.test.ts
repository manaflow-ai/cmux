import { describe, expect, it } from "bun:test";
import { MAX_REQUEST_BYTES, MAX_ROUTES, parseHeartbeat, readBoundedJson } from "../src/validate";

const DEVICE_ID = "11111111-2222-4333-8444-555555555555";

function postRequest(
  body: string | ReadableStream<Uint8Array>,
  headers: Record<string, string> = {},
): Request {
  return new Request("https://presence.example/v1/presence/heartbeat", {
    method: "POST",
    body,
    headers,
  });
}

/** A chunked body with no usable Content-Length, as an attacker would send. */
function chunkedRequest(chunks: readonly Uint8Array[]): Request {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
  return postRequest(stream);
}

describe("readBoundedJson", () => {
  it("accepts a small valid JSON object", async () => {
    const result = await readBoundedJson(postRequest(JSON.stringify({ a: 1 })));
    expect(result).toEqual({ ok: true, value: { a: 1 } });
  });

  it("rejects an oversized declared Content-Length up front", async () => {
    const result = await readBoundedJson(
      postRequest("{}", { "content-length": String(MAX_REQUEST_BYTES + 1) }),
    );
    expect(result).toEqual({ ok: false, status: 413 });
  });

  it("aborts a chunked body the moment it crosses the cap", async () => {
    // Three 8 KiB chunks = 24 KiB > 16 KiB cap, with no Content-Length header
    // to check up front. The reader must stop mid-stream, not buffer it all.
    const chunk = new Uint8Array(8 * 1024).fill(0x61);
    const result = await readBoundedJson(chunkedRequest([chunk, chunk, chunk]));
    expect(result).toEqual({ ok: false, status: 413 });
  });

  it("reassembles a valid body split across chunks", async () => {
    const encoder = new TextEncoder();
    const result = await readBoundedJson(
      chunkedRequest([encoder.encode('{"devi'), encoder.encode('ceId":"x"}')]),
    );
    expect(result).toEqual({ ok: true, value: { deviceId: "x" } });
  });

  it("rejects malformed JSON with 400", async () => {
    const result = await readBoundedJson(postRequest("{not json"));
    expect(result).toEqual({ ok: false, status: 400 });
  });

  it("rejects non-object JSON (arrays, null) with 400", async () => {
    expect(await readBoundedJson(postRequest("[1,2]"))).toEqual({ ok: false, status: 400 });
    expect(await readBoundedJson(postRequest("null"))).toEqual({ ok: false, status: 400 });
  });

  it("rejects a missing body with 400", async () => {
    const request = new Request("https://presence.example/v1/presence/heartbeat", {
      method: "POST",
    });
    expect(await readBoundedJson(request)).toEqual({ ok: false, status: 400 });
  });
});

describe("parseHeartbeat", () => {
  it("accepts a minimal valid heartbeat and defaults the tag", () => {
    const result = parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac" });
    expect(result).toEqual({
      ok: true,
      beat: {
        deviceId: DEVICE_ID,
        tag: "default",
        platform: "mac",
        displayName: undefined,
        capabilities: undefined,
        stopping: undefined,
      },
    });
  });

  it("lowercases the device id and platform", () => {
    const result = parseHeartbeat({ deviceId: DEVICE_ID.toUpperCase(), platform: "MAC" });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.beat.deviceId).toBe(DEVICE_ID);
      expect(result.beat.platform).toBe("mac");
    }
  });

  it("rejects a non-UUID device id", () => {
    expect(parseHeartbeat({ deviceId: "mac-1", platform: "mac" })).toEqual({
      ok: false,
      error: "invalid_device_id",
    });
  });

  it("rejects unknown platforms", () => {
    expect(parseHeartbeat({ deviceId: DEVICE_ID, platform: "amiga" })).toEqual({
      ok: false,
      error: "invalid_platform",
    });
  });

  it("rejects oversized tags", () => {
    expect(parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac", tag: "x".repeat(65) })).toEqual({
      ok: false,
      error: "invalid_tag",
    });
  });

  it("rejects non-string capabilities and oversized capability lists", () => {
    expect(
      parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac", capabilities: [42] }),
    ).toEqual({ ok: false, error: "invalid_capabilities" });
    expect(
      parseHeartbeat({
        deviceId: DEVICE_ID,
        platform: "mac",
        capabilities: Array.from({ length: 33 }, (_, i) => `cap-${i}`),
      }),
    ).toEqual({ ok: false, error: "invalid_capabilities" });
  });

  it("treats only literal true as stopping", () => {
    const result = parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac", stopping: "yes" });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.beat.stopping).toBeUndefined();
  });

  it("carries the Mac-chosen transportMode, omits it when absent, and bounds it", () => {
    const withMode = parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac", transportMode: "cmuxRelay" });
    expect(withMode.ok).toBe(true);
    if (withMode.ok) expect(withMode.beat.transportMode).toBe("cmuxRelay");

    const bare = parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac" });
    if (bare.ok) expect(bare.beat.transportMode).toBeUndefined();

    expect(
      parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac", transportMode: "x".repeat(33) }),
    ).toEqual({ ok: false, error: "invalid_transport_mode" });
  });
});

describe("parseHeartbeat routes", () => {
  function body(routes: unknown): Record<string, unknown> {
    return { deviceId: DEVICE_ID, platform: "mac", routes };
  }

  it("absent routes parse as undefined (unchanged)", () => {
    const result = parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac" });
    if (!result.ok) throw new Error(result.error);
    expect(result.beat.routes).toBeUndefined();
  });

  it("an explicit empty array parses as empty (no routes), not absent", () => {
    const result = parseHeartbeat(body([]));
    if (!result.ok) throw new Error(result.error);
    expect(result.beat.routes).toEqual([]);
  });

  it("plain-object entries pass through opaquely", () => {
    const route = { kind: "lan", host: "192.168.1.10", port: 49152 };
    const result = parseHeartbeat(body([route]));
    if (!result.ok) throw new Error(result.error);
    expect(result.beat.routes).toEqual([route]);
  });

  it("non-object entries are dropped, mirroring the registry route", () => {
    const route = { kind: "lan" };
    const result = parseHeartbeat(body([route, "x", 4, null, [1]]));
    if (!result.ok) throw new Error(result.error);
    expect(result.beat.routes).toEqual([route]);
  });

  it("a present non-array routes value is rejected (must not silently clear)", () => {
    expect(parseHeartbeat(body("lan"))).toEqual({ ok: false, error: "invalid_routes" });
    expect(parseHeartbeat(body(7))).toEqual({ ok: false, error: "invalid_routes" });
    expect(parseHeartbeat(body({ kind: "lan" }))).toEqual({ ok: false, error: "invalid_routes" });
  });

  it("bounds the set at MAX_ROUTES entries", () => {
    const routes = Array.from({ length: MAX_ROUTES + 5 }, (_, i) => ({ port: i }));
    const result = parseHeartbeat(body(routes));
    if (!result.ok) throw new Error(result.error);
    expect(result.beat.routes).toHaveLength(MAX_ROUTES);
  });

  it("bounds cumulative serialized route bytes, keeping the preferred-first prefix", () => {
    // Each entry serializes to ~1100 bytes, so only the first fits the budget.
    const big = (id: string) => ({ id, blob: "x".repeat(1080) });
    const result = parseHeartbeat(body([big("first"), big("second"), big("third")]));
    if (!result.ok) throw new Error(result.error);
    expect(result.beat.routes).toHaveLength(1);
    expect((result.beat.routes?.[0] as { id?: string }).id).toBe("first");
  });

  it("a realistic full route set fits the byte budget untouched", () => {
    const routes = Array.from({ length: MAX_ROUTES }, (_, i) => ({
      id: `route-${i}`,
      kind: "tailscale",
      endpoint: { type: "host_port", host: `host-${i}.tailnet.ts.net`, port: 49152 + i },
    }));
    const result = parseHeartbeat(body(routes));
    if (!result.ok) throw new Error(result.error);
    expect(result.beat.routes).toHaveLength(MAX_ROUTES);
  });
});
