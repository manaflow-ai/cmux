// A browser file's own engine probe (its first launch) skips the file where the browser lane is
// optional and fails it where the lane is required, the same rule requireBrowserLane applies to the
// engines CI installs (#24458 review: a skip after requireBrowserLane passed reported a required
// file's tests as passing while none ran).
import { expect, test } from "bun:test";
import { browserLaneRequired, engineUnavailable } from "./support/requireBrowserLane";

const launch = new Error("TimeoutError: launch: Timeout 30000ms exceeded.\nCall log:\n  - <launched> pid=1");

test("on GitHub Actions the lane is required: an engine that does not launch fails the file, naming the error", () => {
  const env = { CI: "true", GITHUB_ACTIONS: "true" };
  expect(browserLaneRequired(env)).toBe(true);
  const reports: string[] = [];
  expect(() =>
    engineUnavailable("thread-minimap-motion", "webkit", launch, { env, report: (line) => reports.push(line) }),
  ).toThrow(/thread-minimap-motion: webkit did not launch \(TimeoutError: launch: Timeout 30000ms exceeded\.\)/);
  expect(reports).toEqual([]);
});

test("elsewhere the lane is optional: the file skips and says why", () => {
  for (const env of [
    // A fleet step that installs the engines (run-webviews-tests.sh with CMUX_BROWSER_TESTS=1).
    { CI: "true", CMUX_CI_STEP_KEY: "step", CMUX_BROWSER_TESTS: "1" },
    // A Freestyle VM or a laptop that asks for the lane.
    { CMUX_BROWSER_TESTS: "1" },
  ]) {
    expect(browserLaneRequired(env)).toBe(false);
    const reports: string[] = [];
    engineUnavailable("thread-minimap-motion", "webkit", launch, { env, report: (line) => reports.push(line) });
    expect(reports).toEqual([
      "thread-minimap-motion: skipping, webkit did not launch here (TimeoutError: launch: Timeout 30000ms exceeded.); run `bunx playwright install webkit` if it is missing",
    ]);
  }
});
