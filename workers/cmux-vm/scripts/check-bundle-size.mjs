#!/usr/bin/env node
// Fails when the gzipped Worker bundle from `wrangler deploy --dry-run --outdir`
// exceeds the budget. Workers allow 3 MiB gzipped on the free plan and 10 MiB
// paid; this budget keeps cold starts small and catches accidental dependencies.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const BUDGET_GZIP_BYTES = 384 * 1024; // 298 KiB at S1
const dir = process.argv[2] ?? "dist";

const files = readdirSync(dir, { recursive: true })
  .map((entry) => join(dir, String(entry)))
  .filter((path) => statSync(path).isFile() && /\.(m?js|wasm)$/.test(path));
if (files.length === 0) {
  console.error(`no bundle output in ${dir}`);
  process.exit(1);
}
let raw = 0;
let gzip = 0;
for (const file of files) {
  const bytes = readFileSync(file);
  raw += bytes.length;
  gzip += gzipSync(bytes, { level: 9 }).length;
}
const kib = (n) => (n / 1024).toFixed(1);
console.log(`bundle: ${files.length} file(s), ${kib(raw)} KiB raw, ${kib(gzip)} KiB gzip (budget ${kib(BUDGET_GZIP_BYTES)} KiB gzip)`);
if (gzip > BUDGET_GZIP_BYTES) {
  console.error("bundle exceeds its gzip budget");
  process.exit(1);
}
