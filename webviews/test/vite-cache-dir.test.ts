// The webviews test runner (scripts/ci/run-webviews-tests.sh) runs dev server files at once, each
// on its own copy of a warm Vite cache, named by CMUX_VITE_CACHE_DIR. Every config a test serves
// must then optimize into that directory: one that keeps another (vite.config.ts's dev server
// plugin set a cache per port) runs cold beside the others, and cold servers started together
// stall in the optimizer (#19746).
import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const webviews = path.join(import.meta.dir, "..");
const resolve = `
const { resolveConfig } = await import("vite");
const config = await resolveConfig({ configFile: process.env.CONFIG, server: { port: 0 } }, "serve", "development");
console.log("cacheDir=" + config.cacheDir);
`;

describe("CMUX_VITE_CACHE_DIR", () => {
  for (const name of [
    "vite.config.ts",
    "vite.config.acpmux-pane.mjs",
    "vite.config.gallery-dev.ts",
    "vite.config.settings-page.mjs",
  ]) {
    test(`${name} optimizes into it`, () => {
      const cache = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-vite-cache-"));
      try {
        const result = spawnSync(process.execPath, ["-e", resolve], {
          cwd: webviews,
          env: { ...process.env, CONFIG: path.join(webviews, name), CMUX_VITE_CACHE_DIR: cache },
          encoding: "utf8",
          timeout: 60_000,
        });
        expect(result.stdout.match(/^cacheDir=(.*)$/m)?.[1], result.stderr).toBe(cache);
      } finally {
        fs.rmSync(cache, { recursive: true, force: true });
      }
    }, 70_000);
  }
});
