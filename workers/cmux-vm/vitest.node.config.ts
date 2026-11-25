import { defineConfig } from "vitest/config";

// Store tests run in Node against an in-process Postgres (PGlite).
export default defineConfig({
  test: {
    include: ["test/node/**/*.test.ts"],
    environment: "node",
    // Each schema test boots PGlite and replays every migration; shared CI runners took over 5 s (2026-10-21).
    testTimeout: 30_000,
    // Most suites do that boot in beforeEach, which has its own 10 s default: nine hooks timed out at 11.9 to 13.5 s on
    // the feat-cmux-next push run 45456093430 (2026-11-24), which stopped its deploy.
    hookTimeout: 30_000,
    server: { deps: { inline: [/@gdp-ts\/core/] } },
  },
});
