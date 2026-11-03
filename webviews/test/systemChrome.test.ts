import { describe, expect, test } from "bun:test";

import { useSystemChrome } from "./support/systemChrome";

type Options = Record<string, unknown> | undefined;

function fakeBrowserType() {
  const calls: { method: string; args: unknown[] }[] = [];
  return {
    calls,
    launch: async (options?: Options) => (calls.push({ method: "launch", args: [options] }), "browser"),
    launchPersistentContext: async (dir: string, options?: Options) => (
      calls.push({ method: "launchPersistentContext", args: [dir, options] }),
      "context"
    ),
  };
}

describe("useSystemChrome", () => {
  test("a launch with no channel or executable runs the system Google Chrome", async () => {
    const chromium = fakeBrowserType();
    useSystemChrome(chromium, {});
    await chromium.launch({ headless: true });
    await chromium.launch();
    await chromium.launchPersistentContext("/tmp/p", { headless: true });
    expect(chromium.calls.map((c) => c.args.at(-1))).toEqual([
      { headless: true, channel: "chrome" },
      { channel: "chrome" },
      { headless: true, channel: "chrome" },
    ]);
  });

  test("an explicit channel or executablePath is kept", async () => {
    const chromium = fakeBrowserType();
    useSystemChrome(chromium, {});
    await chromium.launch({ channel: "chrome-beta" });
    await chromium.launch({ executablePath: "/x/Chromium" });
    expect(chromium.calls.map((c) => c.args[0])).toEqual([
      { channel: "chrome-beta" },
      { executablePath: "/x/Chromium" },
    ]);
  });

  test("wrapping twice wraps once", async () => {
    const chromium = fakeBrowserType();
    useSystemChrome(chromium, {});
    const once = chromium.launch;
    useSystemChrome(chromium, {});
    expect(chromium.launch).toBe(once);
  });

  test("with CMUX_CHROME_HEADLESS_SHELL, headless launches run that shell and headed ones Chrome", async () => {
    const chromium = fakeBrowserType();
    useSystemChrome(chromium, { CMUX_CHROME_HEADLESS_SHELL: "/cache/chrome-headless-shell" });
    await chromium.launch({ headless: true });
    await chromium.launch();
    await chromium.launch({ headless: false });
    await chromium.launch({ channel: "chrome", headless: true });
    expect(chromium.calls.map((c) => c.args[0])).toEqual([
      { headless: true, executablePath: "/cache/chrome-headless-shell" },
      { executablePath: "/cache/chrome-headless-shell" },
      { headless: false, channel: "chrome" },
      { channel: "chrome", headless: true },
    ]);
  });

  test("CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM=1 leaves Playwright's own Chromium", async () => {
    const chromium = fakeBrowserType();
    useSystemChrome(chromium, { CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM: "1" });
    await chromium.launch({ headless: true });
    expect(chromium.calls[0]?.args[0]).toEqual({ headless: true });
  });
});
