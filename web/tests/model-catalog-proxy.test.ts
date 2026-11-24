import { describe, expect, test } from "bun:test";

import nextConfig from "../next.config";
import { config as proxyConfig } from "../proxy";

// GET /api/models/v1 is the live model catalog from cloud-api (user 2026-11-19, chat 40603):
// nightlies read only this URL and follow no redirects, so it is a proxy rewrite.
describe("/api/models/v1", () => {
  test("is rewritten before the file routes to cloud-api's live catalog", async () => {
    const rewrites = await nextConfig.rewrites?.();
    const beforeFiles = Array.isArray(rewrites) ? rewrites : (rewrites?.beforeFiles ?? []);
    const rule = beforeFiles.find((r) => r.source === "/api/models/v1");
    expect(rule?.destination).toBe("https://cloud-api.cmux.dev/v1/models/catalog");
  });

  test("the locale proxy never touches it", () => {
    const matcher = new RegExp(`^${proxyConfig.matcher[0]}$`);
    expect(matcher.test("/api/models/v1")).toBe(false);
  });
});
