import { afterEach, describe, expect, test } from "bun:test";
import { StackServerApp } from "@hexclave/js";

import { createHexclaveServerApi } from "../services/auth/hexclave/serverApi";
import { stackApiBaseURL, stackTokenIssuerBaseURL } from "../services/auth/stackApiBaseURL";

// Production sets no API URL variable. The Stack SDK then talks to
// api.hexclave.com, but our server-key REST helpers (the webhook mirror reads
// among them) defaulted to api.stack-auth.com, which on 2026-10-12/13 answered
// 37 of 318 calls with 429 against 54 of ~733k on api.hexclave.com. Webhook
// deliveries failed with 503 until a redelivery got through.

const URL_KEYS = [
  "STACK_API_BASE_URL",
  "HEXCLAVE_API_URL_SERVER",
  "NEXT_PUBLIC_HEXCLAVE_API_URL_SERVER",
  "STACK_API_URL_SERVER",
  "NEXT_PUBLIC_STACK_API_URL_SERVER",
  "SERVER_STACK_API_URL",
  "NEXT_PUBLIC_SERVER_STACK_API_URL",
  "SERVER_HEXCLAVE_API_URL",
  "NEXT_PUBLIC_SERVER_HEXCLAVE_API_URL",
  "HEXCLAVE_API_URL",
  "NEXT_PUBLIC_HEXCLAVE_API_URL",
  "STACK_API_URL",
  "NEXT_PUBLIC_STACK_API_URL",
  "HEXCLAVE_URL",
  "NEXT_PUBLIC_HEXCLAVE_URL",
  "STACK_URL",
  "NEXT_PUBLIC_STACK_URL",
] as const;
const saved = Object.fromEntries(URL_KEYS.map((key) => [key, process.env[key]]));
const originalFetch = globalThis.fetch;

/**
 * The API origin a real SDK server app resolves for the current environment
 * (read through its interface, test-only), so our REST helpers are pinned to
 * the same Stack host as the SDK for every configuration.
 */
function sdkServerBaseUrl(): string {
  // The SDK starts a background backend-URL lookup; keep it off the network.
  globalThis.fetch = (async () => { throw new TypeError("network disabled in test"); }) as unknown as typeof fetch;
  const app = new StackServerApp({
    projectId: "00000000-0000-4000-8000-000000000001",
    publishableClientKey: "pck_test",
    secretServerKey: "ssk_test",
    tokenStore: "memory",
  }) as unknown as { _interface: { getApiUrl(): string } };
  return new URL(app._interface.getApiUrl()).origin;
}

function clearUrlEnv(): void {
  for (const key of URL_KEYS) delete process.env[key];
}

afterEach(() => {
  for (const key of URL_KEYS) {
    if (saved[key] === undefined) delete process.env[key];
    else process.env[key] = saved[key];
  }
  globalThis.fetch = originalFetch;
});

describe("Stack REST host", () => {
  test("with no API URL configured, the webhook mirror reads go to the SDK's host", async () => {
    clearUrlEnv();
    const seen: string[] = [];
    const fetchImpl = (async (input: RequestInfo | URL) => {
      seen.push(String(input));
      return Response.json({ items: [], pagination: { next_cursor: null } });
    }) as typeof fetch;
    const api = createHexclaveServerApi({ projectId: "project-1", secretServerKey: "ssk", fetch: fetchImpl });
    await api.listUserTeams("user-1");
    expect(new URL(seen[0]!).origin).toBe("https://api.hexclave.com");
    expect(new URL(seen[0]!).origin).toBe(sdkServerBaseUrl());
  });

  test("every SDK-recognized server or shared API URL variable resolves like the SDK", () => {
    for (const key of URL_KEYS.filter((name) => name !== "STACK_API_BASE_URL")) {
      clearUrlEnv();
      process.env[key] = "https://stack.example.test/";
      expect(stackApiBaseURL()).toBe(sdkServerBaseUrl());
    }
    clearUrlEnv();
    process.env.HEXCLAVE_API_URL = "https://shared.example.test";
    process.env.HEXCLAVE_API_URL_SERVER = "https://server.example.test";
    expect(stackApiBaseURL()).toBe(sdkServerBaseUrl());
    expect(stackApiBaseURL()).toBe("https://server.example.test");
  });

  test("the cmux-only STACK_API_BASE_URL override still wins", () => {
    clearUrlEnv();
    process.env.STACK_API_BASE_URL = "https://override.example.test";
    process.env.HEXCLAVE_API_URL = "https://shared.example.test";
    expect(stackApiBaseURL()).toBe("https://override.example.test");
  });

  test("access-token issuer stays the Stack issuer origin", () => {
    // Stack access tokens carry iss https://api.stack-auth.com/api/v1/projects/<id>
    // whichever host served the session; local verification must keep it.
    clearUrlEnv();
    expect(stackTokenIssuerBaseURL()).toBe("https://api.stack-auth.com");
  });
});
