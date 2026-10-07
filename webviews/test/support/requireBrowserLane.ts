import { describe, test } from "bun:test";

type BrowserLaneOptions = {
  env?: Record<string, string | undefined>;
  report?: (message: string) => void;
  skip?: (name: string) => void;
};

/** Keep module-level engine probes and hooks inside the callback as well as tests. */
export async function requireBrowserLane(
  name: string,
  register: () => void | Promise<void>,
  {
    env = process.env,
    report = console.log,
    skip = (name) => describe.skip(name, () => test("browser lane", () => {})),
  }: BrowserLaneOptions = {},
): Promise<void> {
  if (env.CI !== "true" && env.CMUX_BROWSER_TESTS !== "1") {
    report("browser test skipped: runs only in CI or on a Freestyle VM (set CMUX_BROWSER_TESTS=1 there)");
    skip(name);
    return;
  }
  await register();
}
