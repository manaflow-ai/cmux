import { defineConfig } from "vitest/config";

// Store tests run in Node against an in-process Postgres (PGlite).
export default defineConfig({
  test: {
    include: ["test/node/**/*.test.ts"],
    environment: "node",
    server: { deps: { inline: [/@gdp-ts\/core/] } },
  },
});
