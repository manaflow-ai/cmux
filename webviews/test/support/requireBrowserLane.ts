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
 * Whether this run must run the browser lane: an engine that cannot launch fails the file here
 * rather than skipping it. Only GitHub Actions installs every engine for the lane on every run; a
 * fleet step, a Freestyle VM or a laptop may not have one, and its files skip it.
 */
export function browserLaneRequired(env: Record<string, string | undefined> = process.env): boolean {
  return env.GITHUB_ACTIONS === "true";
}

/** The bounded launch options used by every browser file's engine probe. */
export type BrowserLaunchOptions = { headless: true; timeout: 30_000 };

/** What a browser file's engine probe launches: an engine's `launch`, the Browser it gives closed after. */
type BrowserEngine = { launch(options: BrowserLaunchOptions): Promise<{ close(): Promise<void> }> };

/**
 * A browser file's own engine probe (its first launch, inside requireBrowserLane's callback). It
 * resolves true when `launch` gives a browser, closed again (a second close() when the first fails;
 * a browser that still does not close rejects, never skips). When it fails, where the lane is
 * required (browserLaneRequired) it rejects, naming the launch error, so the file fails rather
 * than reporting tests that never ran (#24458 review); elsewhere it reports why, registers the
 * file's skip and resolves false, and the file registers nothing more. A file probes through this,
 * never with its own describe.skip.
 */
export async function probeEngineOrSkip(
  name: string,
  engineName: string,
  engine: BrowserEngine,
  {
    env = process.env,
    report = console.warn,
    skip = (suite) => describe.skip(suite, () => test(engineName, () => {})),
  }: {
    env?: Record<string, string | undefined>;
    report?: (message: string) => void;
    skip?: (name: string) => void;
  } = {},
): Promise<boolean> {
  const why = (error: unknown) => String(error).split("\n")[0];
  let browser: Awaited<ReturnType<BrowserEngine["launch"]>>;
  try {
    browser = await engine.launch({ headless: true, timeout: 30_000 });
  } catch (error) {
    if (browserLaneRequired(env))
      throw new Error(`${name}: ${engineName} did not launch (${why(error)}), and the browser lane is required here`);
    report(
      `${name}: skipping, ${engineName} did not launch here (${why(error)}); run \`bunx playwright install ${engineName}\` if it is missing`,
    );
    skip(name);
    return false;
  }
  // The engine launched, so the file runs. A close() that fails is tried once more; one that fails
  // again fails the file, required or not, rather than skipping it or leaving the browser to the
  // step's cleanup unnoticed (#24458 review round 3).
  try {
    await browser.close();
  } catch {
    try {
      await browser.close();
    } catch (error) {
      throw new Error(`${name}: ${engineName} launched but did not close (${why(error)})`);
    }
  }
  return true;
}

/**
 * Keep module-level engine probes and hooks inside the callback as well as tests.
 *
 * On GitHub Actions an engine that cannot launch fails the file before it registers anything. The
 * suites skip themselves when their engine is missing, which is right on a laptop but let
 * react-apps-check report them as passing while it ran none of them. Fleet cmux-ci steps run the
 * same files without installing engines, so they keep the skip: the worker sets CI=true on every
 * step (with CMUX_CI_STEP_KEY), and only a step with CMUX_BROWSER_TESTS=1 installs the engines
 * (scripts/ci/run-webviews-tests.sh). Without that skip every fleet webviews step failed each
 * browser file on "Executable doesn't exist" (2026-10-21, all workers).
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
  if (env.CMUX_CI_STEP_KEY && env.CMUX_BROWSER_TESTS !== "1") {
    report("browser test skipped: a fleet step installs the engines only with CMUX_BROWSER_TESTS=1");
    skip(name);
    return;
  }
  if (browserLaneRequired(env)) {
    const missing = await unlaunchable();
    if (missing.length > 0)
      throw new Error(
        `${name}: GitHub Actions cannot launch ${missing.join(" or ")}; install it (playwright install --with-deps --only-shell chromium webkit) rather than skipping the suite`,
      );
  }
  await register();
}
