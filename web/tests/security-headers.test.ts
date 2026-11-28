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

  test("caches only explicit-locale public marketing pages at the edge", () => {
    const docsRoute = securityHeaderRules.find(
      (rule) => rule.source === "/docs/:path*",
    );
    const localizedDocsRoute = securityHeaderRules.find(
      (rule) => rule.source === "/:locale(ja|zh-CN|zh-TW|ko|de|es|fr|it|da|pl|ru|bs|ar|no|pt-BR|th|tr|km|uk)/docs/:path*",
    );
    const dashboardRoute = securityHeaderRules.find(
      (rule) => rule.source === "/dashboard/:path*",
    );

    expect(docsRoute).toBeUndefined();
    expect(localizedDocsRoute?.headers).toEqual([
      {
        key: "Cache-Control",
        value: "public, s-maxage=86400, stale-while-revalidate=604800",
      },
    ]);
    expect(dashboardRoute).toBeUndefined();
  });
});
