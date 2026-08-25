import { defineConfig } from "@playwright/test";

const port = 4173;

export default defineConfig({
  testDir: "./e2e/instant",
  testMatch: "**/*.instant.ts",
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 2 : 0,
  use: {
    baseURL: `http://127.0.0.1:${port}`,
  },
  webServer: {
    command:
      `SKIP_ENV_VALIDATION=1 NEXT_INSTANT_TEST=1 bunx next build && ` +
      `SKIP_ENV_VALIDATION=1 NEXT_INSTANT_TEST=1 bunx next start -p ${port}`,
    port,
    reuseExistingServer: false,
    timeout: 180_000,
  },
});
