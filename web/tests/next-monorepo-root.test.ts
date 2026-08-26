import { describe, expect, test } from "bun:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

import nextConfig from "../next.config";

describe("Next monorepo module boundary", () => {
  test("pins the Turbopack root to the web project", () => {
    const webRoot = path.dirname(fileURLToPath(new URL("../next.config.ts", import.meta.url)));
    expect(nextConfig.turbopack?.root).toBe(webRoot);
  });

  test("enables the Next 16.3 instant navigation stack", () => {
    expect(nextConfig.cacheComponents).toBeTrue();
    expect(nextConfig.partialPrefetching).toBeTrue();
    expect(nextConfig.experimental?.instantInsights).toEqual({
      validationLevel: "warning",
    });
    expect(
      nextConfig.experimental?.exposeTestingApiInProductionBuild,
    ).toBeFalse();
  });
});
