import { describe, test } from "bun:test";

/** The engines CI installs for the browser lane (ci-web.yml react-apps-check). */
const CI_ENGINES = ["chromium", "webkit"] as const;

type BrowserLaneOptions = {
  env?: Record<string, string | undefined>;
  report?: (message: string) => void;
  skip?: (name: string) => void;
  /** The CI engines that cannot launch here. */
  unlaunchable?: () => Promise<string[]>;
};

async function unlaunchableEngines(): Promise<string[]> {
  const playwright = await import("playwright");
  const missing: string[] = [];
  for (const engine of CI_ENGINES) {
    try {
      // Playwright's own launch timeout is three minutes; a broken engine fails sooner.
      await (await playwright[engine].launch({ headless: true, timeout: 30_000 })).close();
    } catch {
      missing.push(engine);
    }
  }
  return missing;
}

/**
 * Keep module-level engine probes and hooks inside the callback as well as tests.
 *
 * On GitHub Actions an engine that cannot launch fails the file before it registers anything. The
 * suites skip themselves when their engine is missing, which is right on a laptop but let
 * react-apps-check report them as passing while it ran none of them. Fleet cmux-ci steps run the
 * same files without installing engines, so they keep the skip.
 */
export async function requireBrowserLane(
  name: string,
  register: () => void | Promise<void>,
  {
    env = process.env,
    report = console.log,
    skip = (name) => describe.skip(name, () => test("browser lane", () => {})),
    unlaunchable = unlaunchableEngines,
  }: BrowserLaneOptions = {},
): Promise<void> {
  if (env.CI !== "true" && env.CMUX_BROWSER_TESTS !== "1") {
    report("browser test skipped: runs only in CI or on a Freestyle VM (set CMUX_BROWSER_TESTS=1 there)");
    skip(name);
    return;
  }
  if (env.GITHUB_ACTIONS === "true") {
    const missing = await unlaunchable();
    if (missing.length > 0)
      throw new Error(
        `${name}: GitHub Actions cannot launch ${missing.join(" or ")}; install it (playwright install --with-deps --only-shell chromium webkit) rather than skipping the suite`,
      );
  }
  await register();
}
