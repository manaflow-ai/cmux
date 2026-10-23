// A browser file's own engine probe (its first launch) skips the file where the browser lane is
// optional and fails it where the lane is required, the same rule requireBrowserLane applies to the
// engines CI installs (#24458 review: a skip after requireBrowserLane passed reported a required
// file's tests as passing while none ran). The files probe through probeEngineOrSkip, so the rule
// tested here is the one they run: a file that skips with its own describe.skip fails this test.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { browserLaneRequired, probeEngineOrSkip } from "./support/requireBrowserLane";

/// Playwright's launch timeout: a TimeoutError whose message goes on with the launch's call log.
const timeout = Object.assign(new Error("launch: Timeout 30000ms exceeded.\nCall log:\n  - <launched> pid=1"), {
  name: "TimeoutError",
});
const failing = () => Promise.reject(timeout);

/// Runs the probe with `launch` under `env`, recording what it reports and skips.
async function probe(env: Record<string, string>, launch: () => Promise<{ close(): Promise<void> }>) {
  const reports: string[] = [];
  const skips: string[] = [];
  const result = probeEngineOrSkip("thread minimap motion", "webkit", launch, {
    env,
    report: (line) => reports.push(line),
    skip: (name) => skips.push(name),
  });
  return { result, reports, skips };
}

test("on GitHub Actions the lane is required: a probe whose engine does not launch fails the file, naming the error", async () => {
  const env = { CI: "true", GITHUB_ACTIONS: "true" };
  expect(browserLaneRequired(env)).toBe(true);
  const { result, reports, skips } = await probe(env, failing);
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
    const { result, reports, skips } = await probe(env, failing);
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

/// The files whose engine probe goes through probeEngineOrSkip: none skips itself, so a failed
/// launch where the lane is required fails it.
const PROBED = ["thread-minimap-motion.test.ts"];

test("the probed files skip only through probeEngineOrSkip", () => {
  for (const file of PROBED) {
    const code = readFileSync(new URL(`./${file}`, import.meta.url), "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/.*$/gm, "");
    // A skip of its own would report the file's tests as passing on GitHub Actions with none run.
    expect({ file, skips: code.match(/\b(?:describe|test|it)\.skip(?:If)?\b/g) ?? [] }).toEqual({ file, skips: [] });
    expect({ file, probes: /\bprobeEngineOrSkip\(/.test(code) }).toEqual({ file, probes: true });
  }
});
