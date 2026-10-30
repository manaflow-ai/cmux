// cmux-web-test-timeout: 240
// Real Chromium exercise of VirtualTranscript's send path. Set CMUX_SEND_SCROLL_CAPTURE_DIR on
// the hosted run to retain before/after images from this same harness.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("send-scroll-setting.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-scroll-setting: skipping (run `bunx playwright install chromium`)");
    describe.skip("send scroll setting", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const captureDir = process.env.CMUX_SEND_SCROLL_CAPTURE_DIR;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/send-scroll-setting.html");
    browser = await chromium.launch({ headless: true });
    if (captureDir) await mkdir(captureDir, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  const row = (id: string, kind: string, text?: string): Row => ({ id, kind, text, version: 1, at: 1 });
  const paragraph = (index: number) =>
    `History ${index}: the keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
    "then watched the light sweep the water before going back down.";
  const history = () =>
    Array.from({ length: 26 }, (_, index) => [
      row(`turn-${index}-user`, "user", `Prompt ${index}`),
      row(`turn-${index}-answer`, "assistant", paragraph(index)),
    ]).flat();
  const show = (page: Page, rows: Row[]) =>
    page.evaluate((next) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(next), rows);
  const send = (page: Page) => page.evaluate(() => (window as unknown as { __send(): void }).__send());
  const frames = (page: Page, count = 3) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left -= 1) await window.cmuxPaintFrame();
    }, count);
  const open = async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/send-scroll-setting.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };
  const capture = async (page: Page, name: string) => {
    if (!captureDir) return;
    const file = path.join(captureDir, `${name}.png`);
    await page.screenshot({ path: file });
    console.log(`SEND_SCROLL_CAPTURE=${file}`);
  };
  const scrollMetrics = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return { top: node.scrollTop, fromEnd: node.scrollHeight - node.clientHeight - node.scrollTop };
    });
  const scrollUp = async (page: Page) => {
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.scrollTop = Math.max(0, node.scrollHeight / 2);
      node.dispatchEvent(new Event("scroll", { bubbles: true }));
    });
    await frames(page, 4);
    await page.waitForFunction(
      () => (window as unknown as { __sendState(): { following: boolean } }).__sendState().following === false,
    );
  };
  const addReply = (rows: Row[], streaming = false) => [
    ...rows,
    row("sent-prompt", "user", "Keep this visible while I read above."),
    { ...row("sent-reply", "assistant", "The reply arrived below your reading position."), streaming },
  ];

  test("off preserves an up-scroll anchor while the prompt and reply arrive below", async () => {
    const page = await open();
    await page.evaluate(() =>
      (window as unknown as { __setScrollToBottomOnSend(enabled: boolean): void }).__setScrollToBottomOnSend(false),
    );
    const rows = history();
    await show(page, rows);
    await frames(page, 5);
    await scrollUp(page);
    const before = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>('[data-row-id="turn-13-answer"]')!;
      (node as HTMLElement & { sendScrollMarker?: object }).sendScrollMarker = {};
      return {
        top: node.getBoundingClientRect().top,
        scroll: document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop,
      };
    });
    await capture(page, "off-before");
    await send(page);
    await show(page, addReply(rows, true));
    await frames(page, 5);
    await show(page, addReply(rows));
    await frames(page, 6);
    const after = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>('[data-row-id="turn-13-answer"]')! as HTMLElement & {
        sendScrollMarker?: object;
      };
      return {
        top: node.getBoundingClientRect().top,
        marker: Boolean(node.sendScrollMarker),
        jump: document.querySelector(".acpmux-jump-latest")?.hasAttribute("data-shown") ?? false,
        state: (window as unknown as { __sendState(): { following: boolean; sends: number } }).__sendState(),
      };
    });
    await capture(page, "off-after");
    expect(Math.abs(after.top - before.top)).toBeLessThanOrEqual(1);
    expect(after.marker).toBe(true);
    expect(after.state).toEqual({ following: false, sends: 0 });
    expect(after.jump).toBe(true);
    await page.close();
  });

  test("on moves an up-scrolled reader to the new reply", async () => {
    const page = await open();
    const rows = history();
    await show(page, rows);
    await frames(page, 5);
    await scrollUp(page);
    await capture(page, "on-before");
    await page.evaluate(() =>
      (window as unknown as { __setScrollToBottomOnSend(enabled: boolean): void }).__setScrollToBottomOnSend(true),
    );
    await send(page);
    await show(page, addReply(rows, true));
    await frames(page, 8);
    await show(page, addReply(rows));
    await frames(page, 14);
    const metrics = await scrollMetrics(page);
    const state = await page.evaluate(() =>
      (window as unknown as { __sendState(): { following: boolean; sends: number } }).__sendState(),
    );
    await capture(page, "on-after");
    expect(metrics.fromEnd).toBeLessThanOrEqual(2);
    expect(state).toEqual({ following: true, sends: 1 });
    await page.close();
  });

  test("off still follows a reply when the reader is already at the bottom", async () => {
    const page = await open();
    const rows = history();
    await page.evaluate(() =>
      (window as unknown as { __setScrollToBottomOnSend(enabled: boolean): void }).__setScrollToBottomOnSend(false),
    );
    await show(page, rows);
    await frames(page, 6);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    await send(page);
    await show(page, addReply(rows, true));
    await frames(page, 8);
    await show(page, addReply(rows));
    await frames(page, 14);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    await page.locator('[data-row-id="sent-reply"]').waitFor({ state: "visible" });
    await page.close();
  });
});
