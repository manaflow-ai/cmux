// The Quick Composer panel is 680 x 220 (QuickComposerPanel.swift). The Chief Dock (about 304 px
// tall, absolutely positioned) cannot fit beside the prompt there: drawn, its mascot sits on the
// prompt and takes its clicks. So the dock is off in the Quick Composer by default, and dogfood
// opts in with {"chief-dock":"on"} while the dock is redesigned for the panel.
//
// The real agent pane (vite.config.acpmux-pane.mjs) as the Quick Composer (the handshake's
// `surface: "quick"`), with a stand-in host and the in-page mock transport. Chromium; CI fails the
// file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/quick-composer-chief-dock.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("quick-composer-chief-dock.test.ts", async () => {
  setDefaultTimeout(240_000);
  /** QuickComposerPanel.swift's panel size. */
  const PANEL = { width: 680, height: 220 };
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("quick-composer-chief-dock: skipping (run `bunx playwright install chromium`)");
    describe.skip("Quick Composer Chief Dock", () => test("chromium", () => {}));
    return;
  }
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
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function quickComposer(
    experiments?: Record<string, string>,
    options: { deferGesture?: boolean } = {},
  ): Promise<Page> {
    const page = await browser!.newPage({ viewport: PANEL });
    await installPaintedFrames(page);
    await page.addInitScript(
      ({ experiments, deferGesture }) => {
        const w = window as unknown as Record<string, unknown>;
        if (experiments) w.cmuxExperiments = experiments;
        let resolveGesture: ((value: unknown) => void) | undefined;
        const gesture = deferGesture
          ? new Promise((resolve) => {
              resolveGesture = resolve;
            })
          : undefined;
        w.__resolveDeferredGesture = () => resolveGesture?.({ ok: true, value: { ticket: "deferred-gesture" } });
        w.__quickNativeCalls = [];
        w.webkit = {
          messageHandlers: {
            agentSession: {
              postMessage: async (message: { method?: string }) => {
                const method = String(message?.method ?? "").replace(/^cmux\.agent\./, "");
                (w.__quickNativeCalls as string[]).push(method);
                if (method === "transport.gesture" && gesture) return gesture;
                return { ok: true, value: null };
              },
            },
          },
        };
        w.cmuxAcpmuxActions = {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, surface: "quick" }),
        };
      },
      { experiments, deferGesture: options.deferGesture === true },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-shell[data-surface='quick'] .acpmux-composer-prompt").waitFor();
    return page;
  }

  /** What a click at the prompt's centre and at its left and right thirds lands on: inside the prompt or not. */
  const promptHits = (page: Page) =>
    page.evaluate(() => {
      const prompt = document.querySelector<HTMLElement>(
        ".acpmux-shell[data-surface='quick'] .acpmux-composer-prompt",
      )!;
      const box = prompt.getBoundingClientRect();
      const y = box.top + box.height / 2;
      return [box.left + box.width / 3, box.left + box.width / 2, box.left + (box.width * 2) / 3].map((x) => {
        const hit = document.elementFromPoint(x, y);
        return hit !== null && (prompt === hit || prompt.contains(hit));
      });
    });

  test("at the panel's 680 x 220 the prompt takes its own clicks: no dock covers it by default", async () => {
    const page = await quickComposer();
    // The surface has taken the handshake's answer (it drew the quick prompt); once its entrance
    // has run and two more frames have painted, a dock it would show is there.
    await page.evaluate(async () => {
      const finite = () =>
        document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });
    expect(await page.locator(".acpmux-chief-dock").count()).toBe(0);
    expect(await promptHits(page)).toEqual([true, true, true]);
    const prompt = page.locator(".acpmux-shell[data-surface='quick'] .acpmux-composer-prompt");
    // A real click (Playwright refuses one that another element would receive) focuses the prompt.
    await prompt.click({ timeout: 5_000 });
    expect(await page.evaluate(() => document.activeElement?.closest(".acpmux-composer-prompt") !== null)).toBe(true);
    await page.close();
  });

  test("dogfood still opts in to the dock with the experiment on", async () => {
    const page = await quickComposer({ "chief-dock": "on" });
    await page.locator(".acpmux-shell[data-surface='quick'] .acpmux-chief-dock").waitFor({ timeout: 10_000 });
    expect(await page.locator(".acpmux-chief-dock").count()).toBe(1);
    await page.close();
  });

  test("Quick Composer waits for the gesture ticket before opening its window", async () => {
    const page = await quickComposer(undefined, { deferGesture: true });
    const prompt = page.locator(".acpmux-composer-prompt .ProseMirror");
    await prompt.fill("send after the key proof");
    await prompt.press("Meta+Enter");
    await page.waitForFunction(() => (window as any).__quickNativeCalls?.includes("transport.gesture"));
    await page.evaluate(() => window.cmuxPaintFrame());
    expect(await page.evaluate(() => (window as any).__quickNativeCalls)).not.toContain("quick.openInWindow");
    await page.evaluate(() => (window as any).__resolveDeferredGesture?.());
    await page.waitForFunction(() => (window as any).__quickNativeCalls?.includes("quick.openInWindow"));
    await page.close();
  });
});
