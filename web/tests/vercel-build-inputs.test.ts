import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { dirname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

import packageJSON from "../package.json";
import nextConfig from "../next.config";

test("keeps relay catalog validation inside the Vercel project", () => {
  const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const buildCommand = packageJSON.scripts["vercel-build"];
  const scriptPath = buildCommand.match(
    /bun\s+(\S*generate-managed-iroh-relay-catalog\.ts)\s+--check/,
  )?.[1];

  expect(scriptPath).toBeDefined();
  const resolvedScript = resolve(webRoot, scriptPath!);
  expect(resolvedScript.startsWith(`${webRoot}${sep}`)).toBe(true);
  expect(existsSync(resolvedScript)).toBe(true);
});

test("generates the Pagefind index before Next traces public files", () => {
  for (const scriptName of ["build", "vercel-build"] as const) {
    const buildCommand = packageJSON.scripts[scriptName];
    const pagefindIndex = buildCommand.indexOf(
      "bun tools/build-docs-search.mjs",
    );
    const nextBuildIndex = buildCommand.indexOf("next build");

    expect(pagefindIndex).toBeGreaterThanOrEqual(0);
    expect(nextBuildIndex).toBeGreaterThan(pagefindIndex);
  }
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
