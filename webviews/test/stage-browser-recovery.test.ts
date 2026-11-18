// Detector for "a dead shared browser hangs a test file to its limit" (test/support/stageBrowser.ts):
// fake browsers whose newPage rejects the way a dead Chromium does (Target.createBrowserContext), or
// never answers, prove that a stage relaunches the browser and retries once, that many workers seeing
// one dead browser relaunch it once, and that a browser which cannot be brought back fails every stage
// in milliseconds with a clear message instead of holding the file to its limit.
import { describe, expect, test } from "bun:test";
import { launchStageBrowser, StageBrowserDead } from "./support/stageBrowser";

const DEAD = "newPage: Protocol error (Target.createBrowserContext): Failed to create browser context.";

type FakePage = { id: string; closed: boolean; close(): Promise<void> };
type Mode = "ok" | "reject" | "hang";
type FakeBrowser = { id: number; mode: Mode; closed: boolean; opened: number; close(): Promise<void> };

function fleet(modes: Mode[], closeHangs = false) {
  const browsers: FakeBrowser[] = [];
  const launch = async (): Promise<FakeBrowser> => {
    const mode = modes[browsers.length] ?? "ok";
    const browser: FakeBrowser = {
      id: browsers.length,
      mode,
      closed: false,
      opened: 0,
      close: () => (closeHangs ? new Promise<void>(() => {}) : ((browser.closed = true), Promise.resolve())),
    };
    browsers.push(browser);
    return browser;
  };
  const open = (browser: FakeBrowser): Promise<FakePage> => {
    browser.opened++;
    if (browser.mode === "reject") return Promise.reject(new Error(DEAD));
    if (browser.mode === "hang") return new Promise<FakePage>(() => {});
    const page: FakePage = {
      id: `${browser.id}/${browser.opened}`,
      closed: false,
      close: async () => {
        page.closed = true;
      },
    };
    return Promise.resolve(page);
  };
  return { browsers, launch, open };
}

describe("stage browser recovery", () => {
  test("a failed createBrowserContext relaunches the browser and the stage gets its page", async () => {
    const { browsers, launch, open } = fleet(["ok", "ok"]);
    const shared = await launchStageBrowser({ launch, open, openTimeoutMs: 200 });
    expect((await shared.page()).id).toBe("0/1");
    browsers[0]!.mode = "reject"; // the browser dies mid-file
    const page = await shared.page();
    expect(page.id).toBe("1/1");
    expect(shared.relaunches).toBe(1);
    expect(shared.failure).toBeUndefined();
    expect(browsers[0]!.closed).toBe(true);
    expect(shared.browser).toBe(browsers[1]!);
  });

  test("eight workers that see one dead browser relaunch it once", async () => {
    const { browsers, launch, open } = fleet(["reject", "ok"]);
    const shared = await launchStageBrowser({ launch, open, openTimeoutMs: 200 });
    const pages = await Promise.all(Array.from({ length: 8 }, () => shared.page()));
    expect(pages.every((page) => page.id.startsWith("1/"))).toBe(true);
    expect(browsers.length).toBe(2);
    expect(shared.relaunches).toBe(1);
  });

  test("a wedged newPage that never answers is a failure at its deadline, not at the file limit", async () => {
    const { browsers, launch, open } = fleet(["hang", "ok"]);
    const shared = await launchStageBrowser({ launch, open, openTimeoutMs: 100 });
    const started = performance.now();
    const page = await shared.page();
    expect(performance.now() - started).toBeLessThan(1_000);
    expect(page.id).toBe("1/1");
    expect(browsers.length).toBe(2);
  });

  test("a browser that cannot be brought back fails each stage quickly with a clear message", async () => {
    const { browsers, launch, open } = fleet(["reject", "reject", "reject", "reject"]);
    const shared = await launchStageBrowser({ launch, open, openTimeoutMs: 100 });
    const started = performance.now();
    // The worker loop the gallery scans run: every stage's open fails; none of them waits.
    const outcomes = await Promise.all(
      Array.from({ length: 8 }, async () => {
        const errors: string[] = [];
        for (let stage = 0; stage < 100; stage++)
          await shared.page().then(
            () => errors.push("opened"),
            (error: unknown) => errors.push(error instanceof StageBrowserDead ? "dead" : String(error)),
          );
        return errors;
      }),
    );
    expect(performance.now() - started).toBeLessThan(2_000);
    expect(outcomes.flat().every((outcome) => outcome === "dead")).toBe(true);
    expect(shared.failure).toContain("Target.createBrowserContext");
    expect(shared.failure).toContain("after a relaunch");
    // One relaunch and one retry, then no more: a dead browser is not relaunched per stage.
    expect(browsers.length).toBe(2);
  });

  test("the relaunch budget ends a browser that keeps dying", async () => {
    const { browsers, launch, open } = fleet(["ok", "ok", "ok", "ok"]);
    const shared = await launchStageBrowser({ launch, open, openTimeoutMs: 100, maxRelaunches: 2 });
    for (let death = 0; death < 2; death++) {
      shared.browser.mode = "reject";
      await shared.page();
    }
    expect(shared.relaunches).toBe(2);
    shared.browser.mode = "reject";
    await expect(shared.page()).rejects.toBeInstanceOf(StageBrowserDead);
    expect(shared.failure).toContain("after 2 relaunch(es)");
    expect(browsers.length).toBe(3);
  });

  test("a hung close of a dead browser or page returns at its deadline", async () => {
    const { launch, open } = fleet(["ok"], true);
    const shared = await launchStageBrowser({ launch, open, closeTimeoutMs: 50 });
    const started = performance.now();
    await shared.closePage({ close: () => new Promise<void>(() => {}) } as never);
    await shared.close();
    expect(performance.now() - started).toBeLessThan(1_000);
  });

  test("a page that answers after its deadline is closed, not leaked", async () => {
    let resolveLate: ((page: FakePage) => void) | undefined;
    const late: FakePage = { id: "late", closed: false, close: async () => void (late.closed = true) };
    let calls = 0;
    const shared = await launchStageBrowser({
      launch: async () => ({ close: async () => {} }),
      open: () =>
        ++calls === 1
          ? new Promise<FakePage>((resolve) => (resolveLate = resolve))
          : Promise.resolve({ id: "fresh", closed: false, close: async () => {} }),
      openTimeoutMs: 50,
    });
    expect((await shared.page()).id).toBe("fresh");
    resolveLate!(late);
    await Promise.resolve();
    await Promise.resolve();
    expect(late.closed).toBe(true);
  });
});
