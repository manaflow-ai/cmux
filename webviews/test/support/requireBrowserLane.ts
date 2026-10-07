import { describe, test } from "bun:test";

type BrowserLaneOptions = {
  env?: { CI?: string; CMUX_BROWSER_TESTS?: string };
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
  // Regression baseline: registration currently runs on every host.
  void env;
  void report;
  void skip;
  await register();
}
