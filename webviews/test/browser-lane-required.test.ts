// A browser file's own engine probe (its first launch) skips the file where the browser lane is
// optional and fails it where the lane is required, the same rule requireBrowserLane applies to the
// engines CI installs (#24458 review: a skip after requireBrowserLane passed reported a required
// file's tests as passing while none ran).
import { expect, test } from "bun:test";
import { browserLaneRequired, probeEngineOrSkip, type BrowserLaunchOptions } from "./support/requireBrowserLane";

/// Playwright's launch timeout: a TimeoutError whose message goes on with the launch's call log.
const timeout = Object.assign(new Error("launch: Timeout 30000ms exceeded.\nCall log:\n  - <launched> pid=1"), {
  name: "TimeoutError",
});
const failing = () => Promise.reject(timeout);

/// Runs the probe with `launch` under `env`, recording what it reports and skips.
async function probe(
  env: Record<string, string | undefined>,
  launch: (options: BrowserLaunchOptions) => Promise<{ close(): Promise<void> }>,
) {
  const reports: string[] = [];
  const skips: string[] = [];
  const result = probeEngineOrSkip(
    "thread minimap motion",
    "webkit",
    { launch },
    {
      env,
      report: (line) => reports.push(line),
      skip: (name) => skips.push(name),
    },
  );
  return { result, reports, skips };
}

test("on GitHub Actions the lane is required: a probe whose engine does not launch fails the file, naming the error", async () => {
  const env = { CI: "true", GITHUB_ACTIONS: "true" };
  expect(browserLaneRequired(env)).toBe(true);
  const { result, reports, skips } = await probe(env, () => failing());
  await expect(result).rejects.toThrow(
    /thread minimap motion: webkit did not launch \(TimeoutError: launch: Timeout 30000ms exceeded\.\)/,
  );
  expect(skips).toEqual([]);
  expect(reports).toEqual([]);
});

test("elsewhere the lane is optional: the probe skips the file and says why", async () => {
  for (const env of [
    // A fleet step that installs the engines (run-webviews-tests.sh with CMUX_BROWSER_TESTS=1).
    { CI: "true", CMUX_CI_STEP_KEY: "step", CMUX_BROWSER_TESTS: "1" },
    // A Freestyle VM or a laptop that asks for the lane.
    { CMUX_BROWSER_TESTS: "1" },
  ]) {
    expect(browserLaneRequired(env)).toBe(false);
    const { result, reports, skips } = await probe(env, () => failing());
    expect(await result).toBe(false);
    expect(skips).toEqual(["thread minimap motion"]);
    expect(reports).toEqual([
      "thread minimap motion: skipping, webkit did not launch here (TimeoutError: launch: Timeout 30000ms exceeded.); run `bunx playwright install webkit` if it is missing",
    ]);
  }
});

test("an engine that launches is closed again and the file goes on, required or not", async () => {
  for (const env of [{ CI: "true", GITHUB_ACTIONS: "true" }, { CMUX_BROWSER_TESTS: "1" }]) {
    let closed = 0;
    const { result, reports, skips } = await probe(env, async () => ({ close: async () => void (closed += 1) }));
    expect(await result).toBe(true);
    expect(closed).toBe(1);
    expect(skips).toEqual([]);
    expect(reports).toEqual([]);
  }
});

// A launched browser whose close() rejects is neither a skip nor a leak: the probe tries close()
// again, and if that fails too it rejects, required or not (#24458 review round 3).
test("a browser that launches but does not close is closed again, and never makes the file skip", async () => {
  for (const env of [{ CI: "true", GITHUB_ACTIONS: "true" }, { CMUX_BROWSER_TESTS: "1" }]) {
    // Once: the second close() closes it, and the file goes on.
    let closes = 0;
    const once = await probe(env, async () => ({
      close: async () => {
        closes += 1;
        if (closes === 1) throw new Error("Target page, context or browser has been closed");
      },
    }));
    expect(await once.result).toBe(true);
    expect(closes).toBe(2);
    expect(once.skips).toEqual([]);
    // Always: the probe rejects, naming the close error; it does not report a skip.
    let tries = 0;
    const never = await probe(env, async () => ({
      close: async () => {
        tries += 1;
        throw new Error("close failed");
      },
    }));
    await expect(never.result).rejects.toThrow(
      /thread minimap motion: webkit launched but did not close \(Error: close failed\)/,
    );
    expect(tries).toBe(2);
    expect(never.skips).toEqual([]);
    expect(never.reports).toEqual([]);
  }
});

test("the probe uses a bounded launch and closes the browser", async () => {
  const options: BrowserLaunchOptions[] = [];
  const { result, reports, skips } = await probe({ CI: "true", CMUX_BROWSER_TESTS: "1" }, async (launchOptions) => {
    options.push(launchOptions);
    return { close: async () => {} };
  });
  expect(await result).toBe(true);
  expect(options).toEqual([{ headless: true, timeout: 30_000 }]);
  expect(skips).toEqual([]);
  expect(reports).toEqual([]);
});
