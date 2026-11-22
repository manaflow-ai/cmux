import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Integration tests run inside workerd with the Worker's own wrangler config.
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
  test: {
    include: ["test/workers/**/*.test.ts"],
    // gdp-ts ships TypeScript sources; let Vite transform them for workerd.
    server: { deps: { inline: [/@gdp-ts\/core/] } },
  },
});
