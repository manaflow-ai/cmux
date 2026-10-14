#!/usr/bin/env node
// Prefer the esbuild bundle; fall back to running the TypeScript sources via tsx.
import { existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const bundle = join(root, "dist", "cli.mjs");
if (existsSync(bundle)) {
  await import(pathToFileURL(bundle).href);
} else {
  const { register } = await import("tsx/esm/api");
  register();
  await import(pathToFileURL(join(root, "src", "cli.ts")).href);
}
