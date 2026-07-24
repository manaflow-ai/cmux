import { describe, expect, test } from "bun:test";
import { poweredByHeader, securityHeaderRules } from "../security-headers";

function responseHeadersFor(paths: string[]): Record<string, Record<string, string>> {
  const moduleURL = new URL("../security-headers.ts", import.meta.url).href;
  const script = `
    import { AsyncLocalStorage } from "node:async_hooks";
    import { securityHeaderRules } from ${JSON.stringify(moduleURL)};
    globalThis.AsyncLocalStorage = AsyncLocalStorage;
    const { unstable_getResponseFromNextConfig } =
      await import("next/experimental/testing/server");
    const paths = ${JSON.stringify(paths)};
    const nextConfig = { async headers() { return securityHeaderRules; } };
    const result = {};
    for (const path of paths) {
      const response = await unstable_getResponseFromNextConfig({
        url: "https://cmux.com" + path,
        nextConfig,
      });
      result[path] = Object.fromEntries(response.headers.entries());
    }
    console.log(JSON.stringify(result));
  `;
  const child = Bun.spawnSync({
    cmd: [process.execPath, "-e", script],
    cwd: import.meta.dir,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (child.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(child.stderr));
  }
  return JSON.parse(new TextDecoder().decode(child.stdout)) as Record<
    string,
    Record<string, string>
  >;
}

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

  test("sends no-referrer before any localized or unlocalized share-page assets", () => {
    const paths = [
      "/share/ABCDEFGH",
      "/en/share/ABCDEFGH",
      "/ja/share/ABCDEFGH",
      "/docs",
    ];
    const headers = responseHeadersFor(paths);

    for (const path of paths.slice(0, 3)) {
      expect(headers[path]?.["referrer-policy"]).toBe("no-referrer");
      expect(headers[path]?.["x-robots-tag"]).toBe("noindex, nofollow");
      expect(headers[path]?.["cache-control"]).toBe("private, no-store");
    }
    expect(headers["/docs"]?.["referrer-policy"]).toBe(
      "strict-origin-when-cross-origin",
    );
  });
});
