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
      await (await playwright[engine].launch({ headless: true })).close();
    } catch {
      missing.push(engine);
    }
  }
  return missing;
}

/**
 * Keep module-level engine probes and hooks inside the callback as well as tests.
 *
 * In CI an engine that cannot launch fails the file before it registers anything. The suites skip
 * themselves when their engine is missing, which is right on a laptop but let react-apps-check
 * report them as passing while it ran none of them.
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
  if (env.CI === "true") {
    const missing = await unlaunchable();
    if (missing.length > 0)
      throw new Error(
        `${name}: CI cannot launch ${missing.join(" or ")}; install it (playwright install --with-deps --only-shell chromium webkit) rather than skipping the suite`,
      );
  }
  await register();
}
