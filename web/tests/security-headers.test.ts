import { describe, expect, test } from "bun:test";
import { contentSecurityPolicy, poweredByHeader, securityHeaderRules } from "../security-headers";

describe("production security headers", () => {
  test("does not expose framework implementation details", () => {
    expect(poweredByHeader).toBe(false);
  });

  test("applies CSP + baseline hardening headers to every route", async () => {
    const allRoutes = securityHeaderRules.find((rule) => rule.source === "/:path*");
    expect(allRoutes).toBeDefined();

    const headers = Object.fromEntries(allRoutes!.headers.map((header) => [header.key, header.value]));
    expect(headers).toMatchObject({
      "Content-Security-Policy": contentSecurityPolicy,
      "Referrer-Policy": "strict-origin-when-cross-origin",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
    });
  });
});

describe("Content-Security-Policy", () => {
  test("blocks external scripts and restricts connect/img origins", () => {
    expect(contentSecurityPolicy).toContain("default-src 'self'");
    // 'unsafe-inline' allows the app's own inline scripts (Next hydration,
    // theme bootstrap) while 'self' blocks external-origin script injection.
    expect(contentSecurityPolicy).toContain("script-src 'self' 'unsafe-inline'");
    expect(contentSecurityPolicy).toContain("style-src 'self' 'unsafe-inline'");
    expect(contentSecurityPolicy).toContain("connect-src 'self' https://r.cmux.com");
    expect(contentSecurityPolicy).toContain("img-src 'self' data: https://github.com https://avatars.githubusercontent.com");
    expect(contentSecurityPolicy).toContain("base-uri 'self'");
    expect(contentSecurityPolicy).toContain("object-src 'none'");
    expect(contentSecurityPolicy).toContain("frame-ancestors 'none'");
  });
});
