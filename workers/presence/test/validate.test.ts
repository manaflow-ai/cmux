import { describe, expect, it } from "bun:test";
import { MAX_REQUEST_BYTES, parseHeartbeat, readBoundedJson } from "../src/validate";

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
});
