#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(fileURLToPath(new URL("..", import.meta.url)));
const bundlePath = join(root, "Resources", "markdown-viewer", "diff-viewer-app", "main.mjs");

const bundle = readFileSync(bundlePath, "utf8");
const compilerCacheCalls = bundle.match(/\b[A-Za-z_$][\w$]*\.c\(\d+\)/g) ?? [];
if (compilerCacheCalls.length < 8) {
  console.error("React Compiler cache calls were not found in the generated diff viewer bundle.");
  process.exit(1);
}

console.log(`React Compiler enabled for diff viewer (${compilerCacheCalls.length} cache sites).`);
