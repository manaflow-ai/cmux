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

/**
 * For a file's own engine probe that failed with `error`: where the lane is required
 * (browserLaneRequired), throws, naming the launch error, so the file fails rather than reporting
 * tests that never ran; elsewhere reports why the file skips, and the caller skips.
 */
export function engineUnavailable(
  name: string,
  engine: string,
  error: unknown,
  {
    env = process.env,
    report = console.warn,
  }: { env?: Record<string, string | undefined>; report?: (message: string) => void } = {},
): void {
  const reason = String(error).split("\n")[0];
  if (browserLaneRequired(env)) throw new Error(`${name}: ${engine} did not launch (${reason}), and the browser lane is required here`);
  report(`${name}: skipping, ${engine} did not launch here (${reason}); run \`bunx playwright install ${engine}\` if it is missing`);
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
