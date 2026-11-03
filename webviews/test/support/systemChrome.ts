// Playwright's Chromium launches run the installed Google Chrome (channel "chrome"), not the build
// Playwright bundles. Every Playwright release up to 1.64.1 bundles a Chromium older than
// 156.0.8078.73 (1.62.1, pinned here, bundles 151.0.7922.34): it lacks the fixes for
// CVE-2026-118306, -118331, -118348 and -118344, and Playwright runs it with --no-sandbox by default.
// System Chrome updates itself. Drop this once the pinned Playwright bundles 156.0.8078.73 or later.
// test/preload.ts applies it to playwright's shared `chromium`, so every test file gets it.

type LaunchOptions = Record<string, unknown> | undefined;
type BrowserTypeLike = {
  launch: (options?: LaunchOptions) => Promise<unknown>;
  launchPersistentContext: (userDataDir: string, options?: LaunchOptions) => Promise<unknown>;
};

const WRAPPED = Symbol.for("cmux.systemChrome");

// Headless launches run Chrome for Testing's chrome-headless-shell at stable, the engine Playwright's
// own headless launches use (same rendering and timing; full Chrome's new headless mode failed
// timing-sensitive tests, run 41567413265), when scripts/ci/ensure-system-chrome.sh fetched it.
function withSystemChrome(options: LaunchOptions, shell: string | undefined): Record<string, unknown> {
  if (options && ("channel" in options || "executablePath" in options)) return options;
  if (shell && options?.headless !== false) return { ...options, executablePath: shell };
  return { ...options, channel: "chrome" };
}

/**
 * Makes `browserType` (playwright's `chromium`) launch the system Google Chrome when the caller
 * names neither a channel nor an executable, or the patched chrome-headless-shell at
 * `CMUX_CHROME_HEADLESS_SHELL` for headless launches. `CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM=1` opts out.
 */
export function useSystemChrome(
  browserType: BrowserTypeLike,
  env: Record<string, string | undefined> = process.env,
): void {
  if (env.CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM === "1") return;
  const marked = browserType as BrowserTypeLike & { [WRAPPED]?: true };
  if (marked[WRAPPED]) return;
  const shell = env.CMUX_CHROME_HEADLESS_SHELL || undefined;
  const launch = browserType.launch.bind(browserType);
  const launchPersistentContext = browserType.launchPersistentContext.bind(browserType);
  browserType.launch = (options) => launch(withSystemChrome(options, shell));
  browserType.launchPersistentContext = (userDataDir, options) =>
    launchPersistentContext(userDataDir, withSystemChrome(options, shell));
  marked[WRAPPED] = true;
}

// No Playwright on Macs (Lawrence, 2026-11-02): no Playwright, Puppeteer or downloaded Chromium on his
// Mac or a fleet Mac. Playwright turns the Chromium sandbox off whatever Chrome it drives, system
// Chrome included, so on a Mac outside GitHub Actions Playwright starts no browser at all. Browser
// files skip first (requireBrowserLane); this is the backstop for any launch that gets past them.

/** The one line every Mac refusal prints (scripts/ci/run-webviews-tests.sh prints the same). */
export const NO_PLAYWRIGHT_ON_MACS =
  "browser lane: not on a Mac (Lawrence's rule: no Playwright on Macs); run it in CI or on a cloud VM";

/** Whether Playwright may not start or attach to a browser here: a Mac outside GitHub Actions. */
export function playwrightRefusedHere(
  env: Record<string, string | undefined> = process.env,
  platform: string = process.platform,
): boolean {
  return platform === "darwin" && env.GITHUB_ACTIONS !== "true";
}

const REFUSED_METHODS = ["launch", "launchPersistentContext", "launchServer", "connect", "connectOverCDP"] as const;

/**
 * On a Mac outside GitHub Actions, makes every launch and connect of `browserTypes` (playwright's
 * chromium, webkit and firefox) reject with NO_PLAYWRIGHT_ON_MACS before Playwright starts anything.
 * Elsewhere it changes nothing.
 */
export function refusePlaywrightOnMacs(
  browserTypes: readonly object[],
  env: Record<string, string | undefined> = process.env,
  platform: string = process.platform,
): void {
  if (!playwrightRefusedHere(env, platform)) return;
  for (const browserType of browserTypes) {
    const methods = browserType as Record<string, unknown>;
    for (const method of REFUSED_METHODS) {
      if (typeof methods[method] === "function")
        methods[method] = () => Promise.reject(new Error(NO_PLAYWRIGHT_ON_MACS));
    }
  }
}
