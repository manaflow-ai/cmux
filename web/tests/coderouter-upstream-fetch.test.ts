import { describe, expect, test } from "bun:test";

import {
  DEFAULT_UPSTREAM_HEADERS_TIMEOUT_MS,
  UpstreamHeadersTimeoutError,
  fetchWithHeadersTimeout,
  upstreamHeadersTimeoutMs,
} from "../services/coderouter/upstreamFetch";

describe("fetchWithHeadersTimeout", () => {
  test("rejects with UpstreamHeadersTimeoutError when headers never arrive", async () => {
    const fetchImpl = ((_input: unknown, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal!.reason), { once: true });
      })) as typeof fetch;
    await expect(fetchWithHeadersTimeout(fetchImpl, "https://upstream.test/v1", { method: "POST" }, 20))
      .rejects.toBeInstanceOf(UpstreamHeadersTimeoutError);
  });

  test("does not abort a body that streams past the header deadline", async () => {
    let pull = 0;
    const body = new ReadableStream<Uint8Array>({
      async pull(controller) {
        pull += 1;
        await new Promise((resolve) => setTimeout(resolve, 15));
        if (pull > 4) {
          controller.close();
          return;
        }
        controller.enqueue(new TextEncoder().encode(`chunk${pull}\n`));
      },
    });
    let signal: AbortSignal | undefined;
    const fetchImpl = (async (_input: unknown, init?: RequestInit) => {
      signal = init?.signal ?? undefined;
      return new Response(body, { status: 200 });
    }) as typeof fetch;
    const response = await fetchWithHeadersTimeout(fetchImpl, "https://upstream.test/v1", {}, 10);
    // Headers arrived inside the deadline; the stream needs ~75 ms more.
    const text = await response.text();
    expect(text).toBe("chunk1\nchunk2\nchunk3\nchunk4\n");
    expect(signal?.aborted).toBe(false);
  });

  test("a caller-supplied signal still aborts the request", async () => {
    const controller = new AbortController();
    const fetchImpl = ((_input: unknown, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
      })) as typeof fetch;
    const pending = fetchWithHeadersTimeout(fetchImpl, "https://upstream.test/v1", { signal: controller.signal }, 5_000);
    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
  });

  test("passes through fetch rejections unchanged", async () => {
    const fetchImpl = (async () => {
      throw new TypeError("fetch failed");
    }) as typeof fetch;
    await expect(fetchWithHeadersTimeout(fetchImpl, "https://upstream.test/v1", {}, 1_000))
      .rejects.toMatchObject({ name: "TypeError", message: "fetch failed" });
  });

  test("reads and bounds the env override", () => {
    expect(upstreamHeadersTimeoutMs({})).toBe(DEFAULT_UPSTREAM_HEADERS_TIMEOUT_MS);
    expect(upstreamHeadersTimeoutMs({ CODEROUTER_UPSTREAM_HEADERS_TIMEOUT_MS: "abc" })).toBe(DEFAULT_UPSTREAM_HEADERS_TIMEOUT_MS);
    expect(upstreamHeadersTimeoutMs({ CODEROUTER_UPSTREAM_HEADERS_TIMEOUT_MS: "30000" })).toBe(30_000);
    expect(upstreamHeadersTimeoutMs({ CODEROUTER_UPSTREAM_HEADERS_TIMEOUT_MS: "1" })).toBe(1_000);
    expect(upstreamHeadersTimeoutMs({ CODEROUTER_UPSTREAM_HEADERS_TIMEOUT_MS: "99999999" })).toBe(30 * 60_000);
  });
});
