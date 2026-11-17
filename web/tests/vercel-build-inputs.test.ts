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
  expect(nextConfig.outputFileTracingIncludes?.["/extensions/og.png"]).toEqual(["./public/logo.png"]);
});

test("every route that reads a public/ file with fs traces that file", async () => {
  // A route reading join(process.cwd(), "public", NAME) at request time throws ENOENT on Vercel unless
  // outputFileTracingIncludes names the file for a pattern matching that route.
  const includes = Object.entries(nextConfig.outputFileTracingIncludes ?? {});
  const missing: string[] = [];
  for await (const file of new Bun.Glob("app/**/{route,opengraph-image,twitter-image}.{ts,tsx}").scan(".")) {
    const source = await Bun.file(file).text();
    const reads = [...source.matchAll(/join\(process\.cwd\(\),\s*"public",\s*"([^"]+)"\)/g)].map((m) => `./public/${m[1]}`);
    if (reads.length === 0) continue;
    const route = `/${file.replace(/^app\//, "").replace(/\/[^/]+$/, "")}`.replace(/\/\([^/]+\)/g, "");
    const name = file.replace(/\.(ts|tsx)$/, "").split("/").pop()!;
    const page = name === "route" ? route : `${route}/${name}`;
    for (const asset of reads) {
      const traced = includes.some(([pattern, files]) => (pattern === page || new Bun.Glob(pattern).match(page)) && files.includes(asset));
      if (!traced) missing.push(`${page} reads ${asset}`);
    }
  }
  expect(missing).toEqual([]);
});

test("includes Cloud VM prompt templates in traced server output", () => {
  expect(nextConfig.outputFileTracingIncludes?.["/*"]).toEqual([
    "./services/vms/images/devbox/cmux-bashrc",
    "./services/vms/images/devbox/cmux-prompt.bash",
  ]);
});
