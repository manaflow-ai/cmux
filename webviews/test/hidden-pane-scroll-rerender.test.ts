// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// While the reader scrolls the chat they see, a page nobody shows draws nothing, however many other chats
// change (Lawrence, 2026-11-18: dropped frames scrolling a short chat on a large real-world profile; Leo:
// "Why should non visible thing even affect the renderer thread anyways?"). The app's agent pages share one
// renderer, so every render a hidden page commits is main-thread time taken from the scrolled page's frames.
//
// The real pane (`?mock`) in three pages of one Chromium renderer, each listing 2,000 sessions: a short chat
// that is shown and scrolled by wheel input, and, hidden (`visibilityState` hidden, as a page in a background
// workspace reads), a long chat and a New Tab page. Every page's mock daemon changes a listed session 8 times
// a second. Over the scroll, the hidden pages commit no React render at all.
// webviews/bench/session-scale-scroll.bench.ts measures the frames the same setup drops.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("hidden-pane-scroll-rerender.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true, args: ["--renderer-process-limit=1"] });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const SIZE = 2000;
  const RATE = 8;

  /// Headless Chromium reports every page visible: `visibilityState` reads `__testShown`, and
  /// `__testShow(shown)` flips it and tells the page, as the app does when it hides or shows one.
  function visibility() {
    const w = window as unknown as { __testShown: boolean; __testShow?: (shown: boolean) => void };
    if (w.__testShow) return;
    w.__testShown = true;
    Object.defineProperty(Document.prototype, "visibilityState", {
      configurable: true,
      get: () => (w.__testShown ? "visible" : "hidden"),
    });
    Object.defineProperty(Document.prototype, "hidden", { configurable: true, get: () => !w.__testShown });
    w.__testShow = (shown: boolean) => {
      if (w.__testShown === shown) return;
      w.__testShown = shown;
      document.dispatchEvent(new Event("visibilitychange"));
    };
  }

  /// Every `1000 / rate` ms one listed session flips its status, told the page as the daemon does.
  async function installDriver({ size, rate }: { size: number; rate: number }) {
    const mockUrl = "/mock.ts";
    const { MockAcpmuxSocket } = await import(/* @vite-ignore */ mockUrl);
    const daemon = MockAcpmuxSocket.live;
    if (!daemon) throw new Error("no mock daemon");
    let round = 0;
    let timer: ReturnType<typeof setInterval> | undefined;
    (window as any).__scale = {
      start() {
        timer ??= setInterval(() => {
          round += 1;
          daemon.changeSession(`listed-${Math.floor(Math.random() * size)}`, (current: Record<string, any>) => ({
            status: current.status === "running" ? "idle" : "running",
            updatedAt: Date.now(),
          }));
        }, 1000 / rate);
      },
      stop() {
        if (timer) clearInterval(timer);
        timer = undefined;
        return round;
      },
    };
  }

  async function open(kind: "chat" | "long" | "newtab"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.addInitScript(
      ({ size, newTab }) => {
        const mock = globalThis as { cmuxAcpmuxMockListSize?: number; __cmuxNewTabContext?: unknown };
        mock.cmuxAcpmuxMockListSize = size;
        if (newTab) mock.__cmuxNewTabContext = {};
      },
      { size: SIZE, newTab: kind === "newtab" },
    );
    await page.addInitScript(visibility);
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    if (kind === "newtab") await page.locator(".nt-screen").first().waitFor({ state: "attached", timeout: 30_000 });
    else {
      const seeded = (await page.evaluate(
        (turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns, { light: true }),
        kind === "chat" ? 30 : 600,
      )) as Record<string, any>;
      expect(seeded.error).toBeUndefined();
      await page.locator(".acpmux-scroll").first().waitFor({ timeout: 60_000 });
    }
    await page.evaluate(installDriver, { size: SIZE, rate: RATE });
    return page;
  }

  const total = (counts: Record<string, number>) => Object.values(counts).reduce((sum, value) => sum + value, 0);

  test("a hidden pane commits no render while the shown chat scrolls and other chats change", async () => {
    const shown = await open("chat");
    const hidden = [await open("long"), await open("newtab")];
    for (const page of hidden) await page.evaluate(() => (window as any).__testShow(false));
    await shown.bringToFront();
    const box = (await shown.locator(".acpmux-scroll").first().boundingBox())!;
    await shown.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const pages = [shown, ...hidden];
    for (const page of pages) await page.evaluate(() => (window as any).__scale.start());
    // fixed-wait: what landed before the pages hid has drawn, so the count below starts from a still page.
    await shown.waitForTimeout(1500);
    for (const page of pages) await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
    const before = await shown
      .locator(".acpmux-scroll")
      .first()
      .evaluate((node) => node.scrollTop);
    for (let notch = 0; notch < 120; notch += 1) {
      await shown.mouse.wheel(0, Math.floor(notch / 30) % 2 === 0 ? -60 : 60);
      // One notch a frame, as a trackpad's stream sends them: the next notch waits for this one's frame.
      await shown.evaluate(() => new Promise((done) => requestAnimationFrame(() => done(null))));
    }
    const after = await shown
      .locator(".acpmux-scroll")
      .first()
      .evaluate((node) => node.scrollTop);
    const renders = (await Promise.all(
      pages.map((page) => page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())),
    )) as Record<string, number>[];
    const changes = await Promise.all(pages.map((page) => page.evaluate(() => (window as any).__scale.stop())));
    console.log(`HIDDEN-PANE-SCROLL-RERENDER ${JSON.stringify({ before, after, renders, changes })}`);
    // The run did what it says: the shown chat scrolled, and every page heard changes throughout.
    expect(Math.abs(after - before) + total(renders[0]!)).toBeGreaterThan(0);
    for (const count of changes) expect(count).toBeGreaterThan(10);
    expect(renders[1], "the hidden long chat's renders during the scroll").toEqual({});
    expect(renders[2], "the hidden New Tab page's renders during the scroll").toEqual({});
  });
});
