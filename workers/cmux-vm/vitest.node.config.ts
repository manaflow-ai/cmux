import { defineConfig } from "vitest/config";

// Store tests run in Node against an in-process Postgres (PGlite).
export default defineConfig({
  test: {
    include: ["test/node/**/*.test.ts"],
    environment: "node",
    // Each schema test boots PGlite and replays every migration; shared CI runners took over 5 s (2026-10-21).
    testTimeout: 30_000,
    server: { deps: { inline: [/@gdp-ts\/core/] } },
  },
});
