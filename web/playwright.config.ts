import { defineConfig } from "@playwright/test"

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: "http://localhost:3777",
    headless: true,
    viewport: { width: 1280, height: 720 },
  },
  webServer: [
    {
      command: "bun run dev",
      port: 3777,
      reuseExistingServer: true,
    },
    {
      command: "PTY_CWD=$(pwd) ../cmuxd/zig-out/bin/cmuxd --port 3778",
      port: 3778,
      reuseExistingServer: true,
    },
  ],
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
})
