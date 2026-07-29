import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";
import { createIrohVercelFirewallCheck } from "../services/iroh/firewall";

describe("Iroh Vercel firewall client", () => {
  test("uses a trusted deployment host and preserves the firewall key contract", async () => {
    let capturedUrl = "";
    let capturedInit: RequestInit | undefined;
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      capturedUrl = String(input);
      capturedInit = init;
      return new Response(null, { status: 204 });
    }) as typeof fetch;
    const check = createIrohVercelFirewallCheck({
      environment: {
        VERCEL_URL: "cmux-preview.vercel.app",
        VERCEL_PROJECT_PRODUCTION_URL: "cmux.com",
        VERCEL_AUTOMATION_BYPASS_SECRET: "bypass",
        RATE_LIMIT_SECRET: "rate-secret",
      },
      fetch: fetcher,
    });
    const signal = new AbortController().signal;
    const result = await check("iroh-rule", {
      request: new Request("https://attacker.example/api/devices/iroh", {
        headers: {
          host: "attacker.example",
          authorization: "Bearer account-token",
          cookie: "other=ignored; _vercel_jwt=preview-token",
          "x-real-ip": "192.0.2.4",
        },
      }),
      rateLimitKey: "account-hash",
      signal,
    });

    expect(result).toEqual({ rateLimited: false });
    expect(capturedUrl).toBe("https://cmux.com/.well-known/vercel/rate-limit-api/iroh-rule");
    expect(capturedInit?.redirect).toBe("manual");
    expect(capturedInit?.signal).toBe(signal);
    const headers = new Headers(capturedInit?.headers);
    const digest = createHash("sha256")
      .update("account-hashiroh-rulebypassrate-secret")
      .digest("hex");
    expect(headers.get("x-vercel-rate-limit-key")).toBe(`account-hash-${digest}`);
    expect(headers.get("x-vercel-protection-bypass")).toBe("bypass");
    expect(headers.get("cookie")).toBe("_vercel_jwt=preview-token");
    expect(headers.get("x-rr-authorization")).toBe("Bearer account-token");
  });

  test("passes cancellation through to the network fetch", async () => {
    let aborted = false;
    const fetcher = ((_input: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      const signal = init?.signal;
      if (!signal) return reject(new Error("missing signal"));
      signal.addEventListener("abort", () => {
        aborted = true;
        reject(signal.reason);
      }, { once: true });
    })) as typeof fetch;
    const check = createIrohVercelFirewallCheck({
      environment: { VERCEL_URL: "cmux-preview.vercel.app" },
      fetch: fetcher,
    });
    const controller = new AbortController();
    const pending = check("iroh-rule", {
      request: new Request("https://cmux-preview.vercel.app/api/devices/iroh"),
      rateLimitKey: "account-hash",
      signal: controller.signal,
    });

    controller.abort(new Error("deadline"));
    await expect(pending).rejects.toThrow("deadline");
    expect(aborted).toBe(true);
  });

  test("fails closed on unexpected firewall responses", async () => {
    const fetcher = (async () => new Response(null, { status: 500 })) as typeof fetch;
    const check = createIrohVercelFirewallCheck({
      environment: { VERCEL_URL: "cmux-preview.vercel.app" },
      fetch: fetcher,
    });

    await expect(check("iroh-rule", {
      request: new Request("https://cmux-preview.vercel.app/api/devices/iroh"),
      rateLimitKey: "account-hash",
      signal: new AbortController().signal,
    })).rejects.toThrow("unexpected_firewall_status");
  });
});
