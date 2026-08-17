import { describe, expect, test } from "bun:test";
import { enforceNativeIngressRateLimit } from "../services/nativeIngressRateLimit";

const request = new Request("https://cmux.test/api/native");

describe("native ingress rate-limit boundary", () => {
  test("is a no-op outside Vercel", async () => {
    let calls = 0;
    const response = await enforceNativeIngressRateLimit({
      request,
      route: "native",
      ruleId: "native-rule",
      isVercel: false,
      check: async () => {
        calls += 1;
        return { rateLimited: true };
      },
    });

    expect(response).toBeNull();
    expect(calls).toBe(0);
  });

  test("returns 429 for a blocked request", async () => {
    const response = await enforceNativeIngressRateLimit({
      request,
      route: "native",
      ruleId: "native-rule",
      isVercel: true,
      check: async () => ({ rateLimited: true }),
    });

    expect(response?.status).toBe(429);
    expect(await response?.json()).toEqual({ error: "rate_limited" });
  });

  test("fails closed when the firewall is unavailable", async () => {
    const response = await enforceNativeIngressRateLimit({
      request,
      route: "native",
      ruleId: "native-rule",
      isVercel: true,
      check: async () => {
        throw new Error("firewall unavailable");
      },
    });

    expect(response?.status).toBe(503);
    expect(await response?.json()).toEqual({ error: "rate_limit_unavailable" });
  });

  test("fails open only when the configured rule was deleted", async () => {
    const response = await enforceNativeIngressRateLimit({
      request,
      route: "native",
      ruleId: "native-rule",
      isVercel: true,
      check: async () => ({ rateLimited: false, error: "not-found" }),
    });

    expect(response).toBeNull();
  });
});
