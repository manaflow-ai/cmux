// Real Chromium from Playwright, against the gallery's mounted composer. The probe drives the
// composition boundary for Korean 2-set, Japanese kana-kanji, Simplified Chinese pinyin and
// Vietnamese Telex, then verifies one exact host prompt and one normal submit Return.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type PromptCall = { method: string; params?: { prompt?: unknown } };

await requireBrowserLane("ime-composer-probes.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("ime-composer-probes: skipping (run `bunx playwright install chromium`)");
    describe.skip("IME composer probes", () => test("chromium", () => {}));
    return;
  }

  let gallery: ViteDevServer | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    const webviews = path.resolve(import.meta.dir, "..");
    const { createServer } = await import("vite");
    gallery = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await gallery.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(gallery, "agent-pane.composer", { browser, params: { variant: "idle" } });
  });

  afterAll(async () => {
    await browser?.close();
    await gallery?.close();
  });

  const stageURL = () =>
    `http://127.0.0.1:${(gallery!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer", {
      variant: "idle",
      width: 760,
    })}`;

  async function dispatchImeKey(page: Page, key: string, isComposing: boolean) {
    await page.evaluate(
      ({ key, isComposing }) => {
        const target = document.activeElement ?? document.body;
        const event = new KeyboardEvent("keydown", {
          key,
          code: key === "Enter" ? "Enter" : key,
          keyCode: 229,
          isComposing,
          bubbles: true,
          cancelable: true,
        });
        if (event.keyCode !== 229) Object.defineProperty(event, "keyCode", { get: () => 229 });
        target.dispatchEvent(event);
      },
      { key, isComposing },
    );
  }

  async function compose(page: Page, preedit: string, committed: string, candidate = false) {
    await page.focus(".acpmux-md");
    await page.evaluate((data) => {
      const field = document.querySelector<HTMLElement>(".acpmux-md")!;
      field.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
      field.dispatchEvent(new CompositionEvent("compositionupdate", { bubbles: true, data }));
    }, preedit);
    if (candidate) {
      await dispatchImeKey(page, "ArrowDown", true);
      await dispatchImeKey(page, "Enter", true);
    }
    // Trusted keyboard input updates the contenteditable while MarkdownField's composition flag is
    // set, matching the IME's committed DOM update. A synthetic composition event does not make
    // Playwright's `insertText` engage the browser's internal composition transaction.
    await page.keyboard.type(committed);
    await page.evaluate((data) => {
      document.querySelector<HTMLElement>(".acpmux-md")!.dispatchEvent(
        new CompositionEvent("compositionend", { bubbles: true, data }),
      );
    }, committed);
    // WebKit sends the candidate-commit key after compositionend as keyCode 229.
    if (candidate) await dispatchImeKey(page, "Enter", false);
  }

  const probes = [
    { name: "Korean 2-set", preedit: "annyeonghaseyo", committed: "안녕하세요", candidate: false },
    { name: "Japanese kana-kanji", preedit: "nihongo", committed: "日本語", candidate: true },
    { name: "Simplified Chinese pinyin", preedit: "nihao", committed: "你好", candidate: true },
    { name: "Vietnamese Telex", preedit: "tieeng Vieetj", committed: "tiếng Việt", candidate: false },
  ] as const;

  for (const probe of probes)
    test(`${probe.name} composition commits once and one Enter sends it`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
      await page.goto(stageURL());
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await compose(page, probe.preedit, probe.committed, probe.candidate);
      await page.waitForFunction(
        (expected) => document.querySelector(".acpmux-md")?.textContent === expected,
        probe.committed,
      );
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => {
        const log = (window as unknown as { cmuxGalleryLog: PromptCall[] }).cmuxGalleryLog;
        return log.some(({ method }) => method === "acpmux session/prompt");
      });
      const result = await page.evaluate(() => {
        const log = (window as unknown as { cmuxGalleryLog: PromptCall[] }).cmuxGalleryLog;
        const prompts = log
          .filter(({ method }) => method === "acpmux session/prompt")
          .map(({ params }) => params?.prompt);
        return {
          prompts,
          draft: document.querySelector<HTMLElement>(".acpmux-md")?.textContent ?? "",
        };
      });
      await page.close();
      expect(result.prompts).toEqual([probe.committed]);
      expect(result.draft).toBe("");
    });
});
