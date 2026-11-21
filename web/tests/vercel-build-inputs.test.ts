import { expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
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

/** Whether a tracing pattern (`*` one segment, `**` any) matches a route path. */
function tracingPatternMatches(pattern: string, page: string): boolean {
  const source = pattern
    .split("**")
    .map((part) => part.split("*").map((text) => text.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*"))
    .join(".*");
  return new RegExp(`^${source}$`).test(page);
}

test("every route that reads a public/ file with fs traces that file", () => {
  // A route reading join(process.cwd(), "public", NAME) at request time throws ENOENT on Vercel unless
  // outputFileTracingIncludes names the file for a pattern matching that route.
  const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const includes = Object.entries(nextConfig.outputFileTracingIncludes ?? {});
  const routeFile = /(^|\/)(route|opengraph-image|twitter-image)\.tsx?$/;
  const files = readdirSync(join(webRoot, "app"), { recursive: true, encoding: "utf8" })
    .map((file) => file.split(sep).join("/"))
    .filter((file) => routeFile.test(file));
  const missing: string[] = [];
  for (const file of files) {
    const source = readFileSync(join(webRoot, "app", file), "utf8");
    const reads = [...source.matchAll(/join\(process\.cwd\(\),\s*"public",\s*"([^"]+)"\)/g)].map((m) => `./public/${m[1]}`);
    if (reads.length === 0) continue;
    const directory = `/${file.replace(/\/?[^/]+$/, "")}`.replace(/\/\([^/]+\)/g, "");
    const name = file.replace(/\.tsx?$/, "").split("/").pop()!;
    const page = name === "route" ? directory : `${directory}/${name}`.replace(/^\/\//, "/");
    for (const asset of reads) {
      const traced = includes.some(([pattern, assets]) => tracingPatternMatches(pattern, page) && assets.includes(asset));
      if (!traced) missing.push(`${page} reads ${asset}`);
    }
  }
  expect(files.length).toBeGreaterThan(0);
  expect(missing).toEqual([]);
});

test("includes Cloud VM prompt templates in traced server output", () => {
  expect(nextConfig.outputFileTracingIncludes?.["/*"]).toEqual([
    "./services/vms/images/devbox/cmux-bashrc",
    "./services/vms/images/devbox/cmux-prompt.bash",
  ]);
});
