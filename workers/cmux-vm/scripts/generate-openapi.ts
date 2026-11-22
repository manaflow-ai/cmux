/**
 * Writes openapi.json from the Effect HttpApi definition in src/api.ts.
 * `--check` fails when the checked-in file differs, and leaves the fresh
 * document at dist/openapi.json so CI can publish it as an artifact.
 *
 *   bun scripts/generate-openapi.ts           # regenerate
 *   bun scripts/generate-openapi.ts --check   # CI
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { OpenApi } from "@effect/platform";
import { CmuxVmApi } from "../src/api.ts";

const root = new URL("..", import.meta.url);
const target = new URL("openapi.json", root);
const text = `${JSON.stringify(OpenApi.fromApi(CmuxVmApi), null, 2)}\n`;

if (/freestyle/i.test(text)) {
  console.error("openapi.json must not name the upstream provider");
  process.exit(1);
}

if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(target, "utf8");
  } catch {
    // Missing counts as stale.
  }
  if (current !== text) {
    mkdirSync(new URL("dist/", root), { recursive: true });
    writeFileSync(new URL("dist/openapi.json", root), text);
    console.error("openapi.json is stale: run `bun run openapi` in workers/cmux-vm and commit the result");
    process.exit(1);
  }
  console.log("openapi.json is current");
} else {
  writeFileSync(target, text);
  console.log(`wrote ${target.pathname}`);
}
