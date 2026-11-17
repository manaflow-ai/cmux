import { afterEach, describe, expect, mock, test } from "bun:test";
import { readLimitedBody } from "../app/extensions/_lib/limited-body";

mock.module("next/cache", () => ({ cacheLife: () => {} }));
const registry = await import("../app/extensions/_lib/registry");

/** A body that counts how many bytes were pulled from it, endless unless `chunks` is given. */
function countingStream(chunkSize: number, chunks = Infinity) {
  const state = { pulled: 0, cancelled: false };
  let sent = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent >= chunks) return controller.close();
      sent += 1;
      state.pulled += chunkSize;
      controller.enqueue(new Uint8Array(chunkSize));
    },
    cancel() {
      state.cancelled = true;
    },
  });
  return { stream, state };
}

describe("remote bodies have a hard size limit before buffering", () => {
  test("a declared Content-Length over the limit is refused without reading", async () => {
    const { stream, state } = countingStream(1024);
    const response = new Response(stream, { headers: { "content-length": String(10 * 1024 * 1024) } });
    expect(await readLimitedBody(response, 1024 * 1024)).toBeNull();
    expect(state.pulled).toBeLessThanOrEqual(1024);
  });

  test("an endless stream with no length stops at the first chunk past the limit", async () => {
    const { stream, state } = countingStream(64 * 1024);
    expect(await readLimitedBody(new Response(stream), 1024 * 1024)).toBeNull();
    expect(state.cancelled).toBe(true);
    expect(state.pulled).toBeLessThanOrEqual(1024 * 1024 + 2 * 64 * 1024);
  });

  test("a body within the limit comes back whole", async () => {
    const { stream } = countingStream(1000, 3);
    expect((await readLimitedBody(new Response(stream), 4000))!.byteLength).toBe(3000);
  });
});

describe("registry answers are size-limited", () => {
  const saved = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = saved;
  });

  test("an oversized registry page reads as unavailable instead of being buffered", async () => {
    const { stream, state } = countingStream(1024 * 1024);
    globalThis.fetch = (async () => new Response(stream, { headers: { "content-type": "application/json" } })) as unknown as typeof fetch;
    expect(await registry.loadAllListings("extension")).toBeNull();
    expect(state.cancelled).toBe(true);
  });
});
