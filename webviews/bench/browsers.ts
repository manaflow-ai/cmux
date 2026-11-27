// The one place a bench gets Playwright's browser types: import `chromium` and `webkit` from here, never from
// "playwright". Every Chromium launch then runs what the tests run (test/support/systemChrome.ts): the patched
// chrome-headless-shell at CMUX_CHROME_HEADLESS_SHELL for a headless launch when scripts/ci/ensure-system-chrome.sh
// fetched it, else the installed Google Chrome (channel "chrome"); a launch that names a channel or an executable
// keeps it. Playwright's own Chromium is never installed on the perf runner, so a bench that launched it failed
// with "Executable doesn't exist" (ui-stability on the perf cron, run 43326639123).
// test/bench-browser-launch.test.ts fails a bench file that imports a browser type from "playwright" directly.
/// <reference types="bun" />
import { chromium, webkit } from "playwright";
// Imported under a name without the `use` prefix: it is no React Hook, and React Doctor's rules-of-hooks reads a
// top-level `use…()` call as one.
import { useSystemChrome as launchSystemChrome } from "../test/support/systemChrome";

launchSystemChrome(chromium);

export { chromium, webkit };
