import { describe, expect, test } from "bun:test";

import nextConfig from "../next.config";
import { config as proxyConfig } from "../proxy";
import { GET } from "../app/api/apple-app-site-association/route";

describe("apple-app-site-association", () => {
  test("names the cmux iOS app for the agent link page", async () => {
    const response = GET();
    expect(response.headers.get("content-type")).toContain("application/json");
    const body = await response.json();
    expect(body.applinks.details).toEqual([
      {
        appIDs: ["7WLXT3NR37.dev.cmux.app.internal"],
        components: [{ "/": "/deeplink/agent" }, { "/": "/*/deeplink/agent" }],
      },
    ]);
  });

  test("is served at /.well-known with no locale redirect", async () => {
    const rewrites = await nextConfig.rewrites?.();
    const beforeFiles = Array.isArray(rewrites) ? rewrites : (rewrites?.beforeFiles ?? []);
    expect(beforeFiles).toContainEqual({
      source: "/.well-known/apple-app-site-association",
      destination: "/api/apple-app-site-association",
    });
    // Next.js compiles the matcher with path-to-regexp; its pattern part is a regexp.
    const pattern = new RegExp(`^${proxyConfig.matcher[0].replace(/^\//, "\\/")}$`);
    expect(pattern.test("/.well-known/apple-app-site-association")).toBe(false);
    expect(pattern.test("/deeplink/agent")).toBe(true);
  });
});
