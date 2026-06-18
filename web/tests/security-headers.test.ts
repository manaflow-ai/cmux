import { describe, expect, test } from "bun:test";
import { poweredByHeader, securityHeaderRules } from "../security-headers";

describe("production security headers", () => {
  test("does not expose framework implementation details", () => {
    expect(poweredByHeader).toBe(false);
  });

  test("applies baseline hardening headers to every route", async () => {
    const allRoutes = securityHeaderRules.find((rule) => rule.source === "/:path*");
    expect(allRoutes).toBeDefined();

    const headers = Object.fromEntries(allRoutes!.headers.map((header) => [header.key, header.value]));
    expect(headers).toMatchObject({
      "Content-Security-Policy": "base-uri 'self'; object-src 'none'; frame-ancestors 'none'",
      "Referrer-Policy": "strict-origin-when-cross-origin",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
    });
  });
});
