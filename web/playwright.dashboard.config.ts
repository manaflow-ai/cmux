import { defineConfig } from "@playwright/test";

// Signed-in browser regressions for the dashboard SPA. Runs against a live
// dev server or preview with a real Stack project:
//   CMUX_WEB_TEST_BASE_URL=http://localhost:4389 \
//   CMUX_E2E_STACK_EMAIL=... CMUX_E2E_STACK_PASSWORD=... \
//   bunx playwright test -c playwright.dashboard.config.ts
export default defineConfig({
  testDir: "./e2e/dashboard",
  testMatch: "**/*.e2e.ts",
  fullyParallel: false,
  workers: 1,
  timeout: 120_000,
  expect: { timeout: 30_000 },
  globalSetup: "./e2e/dashboard/global-setup.ts",
  use: {
    baseURL: process.env.CMUX_WEB_TEST_BASE_URL ?? "http://localhost:4389",
    storageState: "./e2e/dashboard/.auth/state.json",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
});
