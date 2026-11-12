import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { StackServerApp } from "@hexclave/js";

import {
  installStackThrottleFetchGuard,
  resetStackThrottleFetchGuardForTests,
} from "../services/auth/stackThrottleFetchGuard";
import { hasAuthRateLimitSignal } from "../services/vms/authErrors";

// The Stack SDK answers a 429 by sleeping for Retry-After and then walking its
// three API hosts twice: one throttled call becomes six, each one waiting,
// while the request that made it is already past its deadline. Production saw
// those calls stack up behind every throttle (CODEROUTER-WEB-1R timeouts).
// With the guard, a Stack 429 is final for the SDK call that received it.

const PROJECT_ID = "00000000-0000-4000-8000-000000000001";
const originalFetch = globalThis.fetch;

type Recorded = { url: string };

function throttlingFetch(recorded: Recorded[], retryAfter = "1", requestId: string | null = null): typeof fetch {
  return (async (input: RequestInfo | URL) => {
    const url = input instanceof Request ? input.url : String(input);
    recorded.push({ url });
    return new Response(JSON.stringify({ error: "rate limited" }), {
      status: 429,
      headers: { "retry-after": retryAfter, ...(requestId ? { "x-hexclave-request-id": requestId } : {}) },
    });
  }) as typeof fetch;
}

function app() {
  return new StackServerApp({
    projectId: PROJECT_ID,
    publishableClientKey: "pck_test",
    secretServerKey: "ssk_test",
    tokenStore: "memory",
  });
}

afterEach(() => {
  globalThis.fetch = originalFetch;
  resetStackThrottleFetchGuardForTests(globalThis);
});

describe("Stack throttle fetch guard", () => {
  test("a Stack 429 reaches the caller after one call, without the SDK's waits or host walk", async () => {
    const recorded: Recorded[] = [];
    globalThis.fetch = throttlingFetch(recorded);
    installStackThrottleFetchGuard(globalThis, PROJECT_ID);
    // The SDK logs "Rate limited while sending request ..." exactly when it
    // enters its Retry-After wait; that branch must never run.
    const logged: string[] = [];
    const consoleLog = spyOn(console, "log").mockImplementation((...args: unknown[]) => {
      logged.push(args.map(String).join(" "));
    });
    let failure: unknown;
    try {
      failure = await app().getUser("00000000-0000-4000-8000-000000000002").then(
        () => null,
        (error: unknown) => error,
      );
    } finally {
      consoleLog.mockRestore();
    }
    expect(logged.filter((line) => line.includes("Rate limited"))).toEqual([]);
    expect(recorded.filter((call) => call.url.includes("/users/"))).toHaveLength(1);
    expect(hasAuthRateLimitSignal(failure)).toBe(true);
  });

  test("other hosts and other statuses pass through untouched", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) =>
      new Response(String(input), { status: String(input).includes("teapot") ? 418 : 429 })) as typeof fetch;
    installStackThrottleFetchGuard(globalThis, PROJECT_ID);
    const other = await fetch("https://example.com/limited");
    expect(other.status).toBe(429);
    const stackTeapot = await fetch("https://stack.test/api/v1/teapot", {
      headers: { "x-hexclave-project-id": PROJECT_ID, "x-hexclave-random-nonce": "n" },
    });
    expect(stackTeapot.status).toBe(418);
    // Our own server-key REST helpers send no SDK nonce and read the 429 themselves.
    const ownHelper = await fetch("https://stack.test/api/v1/contact-channels", {
      headers: { "x-hexclave-project-id": PROJECT_ID },
    });
    expect(ownHelper.status).toBe(429);
  });

  test("installing twice wraps fetch once", async () => {
    const recorded: Recorded[] = [];
    globalThis.fetch = throttlingFetch(recorded, "0");
    installStackThrottleFetchGuard(globalThis, PROJECT_ID);
    const once = globalThis.fetch;
    installStackThrottleFetchGuard(globalThis, PROJECT_ID);
    expect(globalThis.fetch).toBe(once);
  });
});
