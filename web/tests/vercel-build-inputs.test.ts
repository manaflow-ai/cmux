import { expect, test } from "bun:test";

import packageJSON from "../package.json";
import nextConfig from "../next.config";

test("builds the docs search index before Next captures public assets", () => {
  const buildCommand = packageJSON.scripts["vercel-build"];
  const searchIndexPosition = buildCommand.indexOf("build-docs-search.mjs");
  const nextBuildPosition = buildCommand.indexOf("next build");

  expect(searchIndexPosition).toBeGreaterThanOrEqual(0);
  expect(nextBuildPosition).toBeGreaterThanOrEqual(0);
  expect(searchIndexPosition).toBeLessThan(nextBuildPosition);
});

test("includes every dynamically read Open Graph asset in traced route output", () => {
  expect(nextConfig.outputFileTracingIncludes?.["**/opengraph-image"]).toEqual([
    "./app/lib/open-graph-fonts/**/*",
    "./app/**/assets/landing-image.png",
    "./public/logo.png",
  ]);
  expect(
    nextConfig.outputFileTracingIncludes?.["**/browser-opengraph-image"],
  ).toEqual(["./public/logo.png"]);
});
