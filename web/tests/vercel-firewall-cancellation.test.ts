import { afterEach, expect, mock, test } from "bun:test";
import { checkRateLimit } from "@vercel/firewall";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("the Firewall SDK passes cancellation to its real transport", async () => {
  const signal = AbortSignal.timeout(20);
  const calls: RequestInit[] = [];
  globalThis.fetch = mock(async (_url: unknown, init: RequestInit) => {
    calls.push(init);
    return new Response(null, { status: 204 });
  }) as unknown as typeof fetch;

  await checkRateLimit("test-rule", {
    request: new Request("https://cmux.test/api/client-config", { headers: { host: "cmux.test" } }),
    rateLimitKey: "test-install",
    firewallHostForDevelopment: "ignore-for-testing",
    signal,
  });

  expect(calls).toHaveLength(1);
  expect(calls[0]?.signal).toBe(signal);
});

test("a stalled Firewall request aborts instead of retaining the shared load", async () => {
  const signal = AbortSignal.timeout(20);
  let transportAborted = false;
  globalThis.fetch = mock((_url: unknown, init: RequestInit) => new Promise<Response>((_, reject) => {
    init.signal?.addEventListener("abort", () => {
      transportAborted = true;
      reject(init.signal?.reason);
    }, { once: true });
  })) as unknown as typeof fetch;

  await expect(checkRateLimit("test-rule", {
    request: new Request("https://cmux.test/api/client-config", { headers: { host: "cmux.test" } }),
    rateLimitKey: "test-install",
    firewallHostForDevelopment: "ignore-for-testing",
    signal,
  })).rejects.toThrow();
  expect(transportAborted).toBe(true);
});
