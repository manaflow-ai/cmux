import { describe, expect, test } from "bun:test";

import { refusePlaywrightOnMacs, useSystemChrome } from "./support/systemChrome";

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

// No Playwright on Macs (Lawrence, 2026-11-02): on a Mac outside GitHub Actions every Playwright
// launch or connect rejects before Playwright starts a browser, system Chrome included (Playwright
// turns the Chromium sandbox off whatever Chrome it drives). test/preload.ts applies this to
// chromium, webkit and firefox, after useSystemChrome.
describe("refusePlaywrightOnMacs", () => {
  const message = "browser lane: not on a Mac (Lawrence's rule: no Playwright on Macs); run it in CI or on a cloud VM";

  function fakeEngine() {
    const calls: string[] = [];
    const record = (method: string) => async () => (calls.push(method), method);
    return {
      calls,
      launch: record("launch"),
      launchPersistentContext: record("launchPersistentContext"),
      launchServer: record("launchServer"),
      connect: record("connect"),
      connectOverCDP: record("connectOverCDP"),
    };
  }
  const methods = ["launch", "launchPersistentContext", "launchServer", "connect", "connectOverCDP"] as const;

  test("on a Mac outside GitHub Actions every launch and connect rejects, naming the rule", async () => {
    const chromium = fakeEngine();
    const webkit = fakeEngine();
    useSystemChrome(chromium, {});
    refusePlaywrightOnMacs([chromium, webkit], {}, "darwin");
    for (const engine of [chromium, webkit])
      for (const method of methods)
        await expect((engine[method] as (...a: unknown[]) => Promise<unknown>)("/tmp/p", {})).rejects.toThrow(message);
    expect([...chromium.calls, ...webkit.calls]).toEqual([]);
  });

  test("Linux and GitHub Actions keep every launch", async () => {
    for (const [env, platform] of [
      [{}, "linux"],
      [{ GITHUB_ACTIONS: "true" }, "darwin"],
    ] as const) {
      const webkit = fakeEngine();
      refusePlaywrightOnMacs([webkit], env, platform);
      for (const method of methods) await (webkit[method] as (...a: unknown[]) => Promise<unknown>)("/tmp/p", {});
      expect(webkit.calls).toEqual([...methods]);
    }
  });
});
