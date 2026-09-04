import { defineConfig } from "@playwright/test";

const port = 4173;

// Keep Stack configured in the production-style server. Requests have no
// session cookie, so the server gate must redirect before it renders the shell.
const dashboardTestEnv =
  "NEXT_PUBLIC_STACK_PROJECT_ID=123e4567-e89b-12d3-a456-426614174000 " +
  "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY=pck_instant_navigation_test " +
  "STACK_SECRET_SERVER_KEY=ssk_instant_navigation_test";

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
    // The repository uses tsgo for its type gate. The split Next.js build runs
    // compile and page generation without repeating the incompatible tsc gate.
    command:
      `${dashboardTestEnv} SKIP_ENV_VALIDATION=1 NEXT_INSTANT_TEST=1 bun run typecheck && ` +
      `${dashboardTestEnv} SKIP_ENV_VALIDATION=1 NEXT_INSTANT_TEST=1 ` +
      `bunx next build --experimental-build-mode compile && ` +
      `${dashboardTestEnv} SKIP_ENV_VALIDATION=1 NEXT_INSTANT_TEST=1 ` +
      `bunx next build --experimental-build-mode generate && ` +
      `${dashboardTestEnv} SKIP_ENV_VALIDATION=1 NEXT_INSTANT_TEST=1 ` +
      `bunx next start -p ${port}`,
    port,
    reuseExistingServer: false,
    timeout: 180_000,
  },
});
