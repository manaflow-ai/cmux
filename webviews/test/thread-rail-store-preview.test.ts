// l10n-allow-file: fixture transcript text, never shipped UI.
// Oldest rail previews must fill while the full prompt index is unavailable. The transcript holds
// only its tail: a preview reads the bounded store endpoint and a click separately loads its target.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";
import { warmViteServer } from "./support/warmDevServer";

type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
const TOTAL = 1_200;
const HELD = 12;
const turn = (index: number): Row[] => {
  const seq = index * 3 + 1;
  return [
    { id: `user-${seq}`, kind: "user", text: `Stored question ${index + 1}.`, version: 1, at: seq },
    { id: `answer-${seq + 1}`, kind: "assistant", text: `Stored answer ${index + 1}.\n\nA second paragraph.`, version: 1, at: seq },
    { id: `summary-${seq + 2}`, kind: "turnSummary", status: "completed", durationMs: 1_000, version: 1, at: seq },
  ];
};
const ALL = Array.from({ length: TOTAL }, (_, index) => turn(index)).flat();

await requireBrowserLane("thread-rail-store-preview.test.ts", async () => {
  setDefaultTimeout(120_000);
  if (!(await probeEngineOrSkip("thread rail store preview", "chromium", chromium))) return;
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    const webviews = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const painted = (page: Page) => page.evaluate(() => window.cmuxPaintFrame());
  async function showOldest(page: Page) {
    await page.evaluate(() => {
      const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
      list.dispatchEvent(new WheelEvent("wheel", { deltaY: -1, bubbles: true }));
      list.scrollTop = 0;
    });
    await page.waitForSelector('[data-tick="0"]');
    await painted(page);
  }
  async function pointAt(page: Page, index: number) {
    return page.evaluate((at) => {
      const box = document.querySelector<HTMLElement>(`[data-tick="${at}"]`)!.getBoundingClientRect();
      return { x: box.left + 8, y: box.top + box.height / 2 };
    }, index);
  }

  // API fixture is wired below once the production preview transport's typed contract is present.
});
