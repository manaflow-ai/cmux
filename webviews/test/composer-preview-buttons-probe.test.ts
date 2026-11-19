// l10n-allow-file: typed fixture text, not shipped UI.
// PROBE (temporary): per-frame boxes of the composer, its attachment preview and its controls while an
// attachment appears, settles and goes away, and while the prompt grows 1 -> 8 lines.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdirSync, writeFileSync } from "node:fs";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { installPaintedFrames } from "./support/paintedFrames";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

await requireBrowserLane("composer-preview-buttons-probe.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT ?? path.join(webviews, "artifacts", "composer-preview-buttons");
  mkdirSync(out, { recursive: true });
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
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

  async function newChat(width: number, look: "claude" | "codex"): Promise<Page> {
    const page = await browser.newPage({ viewport: { width, height: 700 } });
    await page.addInitScript((look) => {
      try {
        localStorage.setItem("cmux.agentPane.composerLook", look);
      } catch {}
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    }, look);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.locator(COMPOSER_EDITOR).click();
    await installPaintedFrames(page);
    return page;
  }

  const start = (page: Page) =>
    page.evaluate(() => {
      const r = (el: Element | null | undefined) => {
        if (!el) return null;
        const b = el.getBoundingClientRect();
        return b.width > 0 ? { top: +b.top.toFixed(1), bottom: +b.bottom.toFixed(1), h: +b.height.toFixed(1) } : null;
      };
      const frames: unknown[] = [];
      const stop = window.cmuxAfterPaint(() => {
        const box = document.querySelector(".acpmux-composer-box")!;
        frames.push({
          box: r(box),
          field: r(box.querySelector(".acpmux-md-field")),
          line1: r(box.querySelector(".ProseMirror > *")),
          strip: r(box.querySelector(".acpmux-attachments")),
          tile: r(box.querySelector(".acpmux-md-inline-chip, .acpmux-attachments .acpmux-attachment")),
          plus: r(box.querySelector(".acpmux-composer-plus")),
          send: r(box.querySelector(".acpmux-composer-actions")),
        });
      });
      Object.assign(window, { __probe: { frames, stop } });
    });
  const finish = async (page: Page, label: string) => {
    for (let i = 0; i < 20; i++) await page.evaluate(() => window.cmuxPaintFrame());
    const frames = (await page.evaluate(() => {
      const p = (window as unknown as { __probe: { frames: unknown[]; stop(): void } }).__probe;
      p.stop();
      return p.frames;
    })) as Record<string, { top: number; bottom: number; h: number } | null>[];
    const lines = frames
      .map((f) =>
        Object.entries(f)
          .map(([k, v]) => `${k}=${v ? `${v.top}..${v.bottom}` : "-"}`)
          .join(" "),
      )
      .filter((line, i, all) => i === 0 || line !== all[i - 1]);
    console.log(`\n### ${label} (${frames.length} frames, ${lines.length} distinct)\n${lines.join("\n")}`);
    writeFileSync(path.join(out, `${label}.json`), JSON.stringify(frames, null, 1));
    return frames;
  };

  const makeImage = (page: Page, width: number, height: number) =>
    page.evaluate(
      async ({ width, height }) => {
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        const c = canvas.getContext("2d")!;
        c.fillStyle = "#335";
        c.fillRect(0, 0, width, height);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
        Object.assign(window, { __img: new File([blob], "shot.png", { type: "image/png" }) });
      },
      { width, height },
    );
  const paste = (page: Page, text?: string) =>
    page.evaluate(
      ({ prompt, text }) => {
        const data = new DataTransfer();
        if (text) data.setData("text/plain", text);
        else data.items.add((window as unknown as { __img: File }).__img);
        const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
        if (event.clipboardData !== data) Object.defineProperty(event, "clipboardData", { value: data });
        document.querySelector(prompt)!.dispatchEvent(event);
      },
      { prompt: COMPOSER_EDITOR, text },
    );
  const settle = (page: Page) =>
    page.waitForFunction(() => document.querySelector(".acpmux-md-field")!.getAnimations().length === 0);

  for (const look of ["claude", "codex"] as const)
    for (const width of [900, 420]) {
      const tag = `${look}-w${width}`;
      test(`${tag}: image preview appears and goes`, async () => {
        const page = await newChat(width, look);
        await makeImage(page, 1600, 1000);
        await page.screenshot({ path: path.join(out, `${tag}-empty.png`) });
        await start(page);
        await paste(page);
        await page.waitForFunction(
          () => !document.querySelector('.acpmux-composer-box [aria-busy="true"]'),
          undefined,
          { timeout: 10_000 },
        );
        await finish(page, `${tag}-image-in`);
        await page.screenshot({ path: path.join(out, `${tag}-with-preview.png`) });
        await start(page);
        await page.keyboard.press("Backspace");
        await finish(page, `${tag}-image-out`);
        await start(page);
        await paste(page, Array.from({ length: 80 }, (_, i) => `pasted line ${i}`).join("\n"));
        await finish(page, `${tag}-text-in`);
        await page.close();
      });
      test(`${tag}: text grows 1 to 8 lines`, async () => {
        const page = await newChat(width, look);
        await page.keyboard.type("line 1");
        await settle(page);
        await start(page);
        for (let n = 2; n <= 8; n++) {
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.type(`line ${n}`);
          await settle(page);
        }
        await finish(page, `${tag}-grow`);
        await page.screenshot({ path: path.join(out, `${tag}-multiline.png`) });
        await page.close();
      });
    }
});
