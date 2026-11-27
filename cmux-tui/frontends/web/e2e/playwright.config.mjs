// Linux end-to-end checks of the web frontend against a real headless daemon.
// CMUX_TUI_BIN: the cmux-tui binary; CMUX_TUI_PAGES_DIR: a folder holding this
// app built as the page `web` (vp build --base ./ --outDir $CMUX_TUI_PAGES_DIR/web).
// The browser is system Chrome or chrome-headless-shell (scripts/ci/ensure-system-chrome.sh),
// never Playwright's bundled Chromium.
import { defineConfig } from "@playwright/test";

const executablePath = process.env.CMUX_CHROME_HEADLESS_SHELL || process.env.CMUX_CHROME || "/usr/bin/google-chrome";

export default defineConfig({
  testDir: ".",
  testMatch: /.*\.e2e\.mjs$/,
  timeout: 60_000,
  retries: 0,
  reporter: [["list"]],
  use: {
    headless: true,
    viewport: { width: 1280, height: 800 },
    launchOptions: { executablePath },
  },
});
