import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { tmpdir } from "node:os";
import { defineConfig } from "vitest/config";

// workerd's SQLite writes its temp files to SQLITE_TMPDIR, else TMPDIR, else /var/tmp: on a runner whose /var/tmp was
// unlinked that failed Durable Object writes with SQLITE_CANTOPEN (backend/apps/api/vitest.config.ts has the runs).
process.env.SQLITE_TMPDIR ||= process.env.RUNNER_TEMP || tmpdir();

// Integration tests run inside workerd with the Worker's own wrangler config.
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
  test: {
    include: ["test/workers/**/*.test.ts"],
    // A file's first Durable Object calls pay workerd's cold start; on a shared runner two create-ledger-do tests
    // passed 5 s (cmux-vm.yml run 44898774325), which made `check` red and would roll back a Cloud image.
    testTimeout: 30_000,
    // gdp-ts ships TypeScript sources; let Vite transform them for workerd.
    server: { deps: { inline: [/@gdp-ts\/core/] } },
  },
});
