// cmux-web-test-timeout: 300
// CDP changes Chromium's actual marked range: no replacing ProseMirror's DOM by hand.
// These traces cover the browser boundary, not an installed OS input method's candidate UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("ime-composer-probes.browser.test.ts", async () => {
  setDefaultTimeout(60_000);
  if (!(await probeEngineOrSkip("IME composer probes", "chromium", chromium))) return;
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
    await warmGalleryFrame(gallery, "agent-pane.composer-ime", {
      browser,
      params: { variant: "empty" },
    });
  }, 180_000);

  afterAll(async () => {
    await browser?.close();
    await gallery?.close();
  });

  async function openComposer() {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    const port = (gallery!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-ime", { variant: "empty", width: 760 })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-md").focus();
    return page;
  }

  async function sent(page: Page) {
    return JSON.parse((await page.locator('output[aria-label="Sent prompts"]').textContent())!);
  }

  async function submit(page: Page, expected: string) {
    expect(await page.locator(".acpmux-md").textContent()).toBe(expected);
    expect(await sent(page)).toEqual([]);
    await page.locator(".acpmux-md").press("Enter");
    await page.waitForFunction(() => document.querySelector('output[aria-label="Sent prompts"]')?.textContent !== "[]");
    expect(await sent(page)).toEqual([expected]);
    expect(await page.locator(".acpmux-md").textContent()).toBe("");
  }

  test("plain typing reaches the real composer send callback", async () => {
    const page = await openComposer();
    try {
      await page.keyboard.insertText("hello");
      await submit(page, "hello");
    } finally {
      await page.close();
    }
  });

  const probes = [
    {
      name: "korean",
      updates: [
        "ㅇ",
        "아",
        "안",
        "안ㄴ",
        "안녀",
        "안녕",
        "안녕ㅎ",
        "안녕하",
        "안녕하ㅅ",
        "안녕하세",
        "안녕하세ㅇ",
        "안녕하세여",
        "안녕하세요",
      ],
      committed: "안녕하세요",
      candidate: false,
    },
    {
      name: "japanese",
      updates: ["に", "にほ", "にほん", "にほんご", "日本語"],
      committed: "日本語",
      candidate: true,
    },
    {
      name: "chinese",
      updates: ["n", "ni", "nih", "nihao", "你好"],
      committed: "你好",
      candidate: true,
    },
    {
      name: "vietnamese",
      updates: [
        "t",
        "ti",
        "tie",
        "tiê",
        "tiên",
        "tiêng",
        "tiếng",
        "tiếng V",
        "tiếng Vi",
        "tiếng Vie",
        "tiếng Viê",
        "tiếng Viêt",
        "tiếng Việt",
      ],
      committed: "tiếng Việt",
      candidate: false,
    },
  ];

  for (const probe of probes) {
    test(`${probe.name}: replacing preedit and committing preserves one exact prompt`, async () => {
      const page = await openComposer();
      const cdp = await page.context().newCDPSession(page);
      try {
        for (const text of probe.updates) {
          await cdp.send("Input.imeSetComposition", {
            text,
            selectionStart: text.length,
            selectionEnd: text.length,
          });
          expect(await page.locator(".acpmux-md").textContent()).toBe(text);
          expect(await sent(page)).toEqual([]);
        }
        if (probe.candidate) {
          // Candidate navigation/confirmation belongs to the input method, not the composer.
          await page.locator(".acpmux-md").evaluate((field) => {
            for (const key of ["ArrowDown", "Enter"]) {
              field.dispatchEvent(
                new KeyboardEvent("keydown", {
                  key,
                  keyCode: 229,
                  isComposing: true,
                  bubbles: true,
                  cancelable: true,
                }),
              );
            }
          });
          expect(await sent(page)).toEqual([]);
        }
        // Some input methods deliver Return as paragraph input, without a useful keydown.
        // The event flag and the composition lifecycle each protect the unfinished draft.
        for (const isComposing of [true, false]) {
          const proceeded = await page.locator(".acpmux-md").evaluate((field, isComposing) => {
            return field.dispatchEvent(
              new InputEvent("beforeinput", {
                inputType: "insertParagraph",
                isComposing,
                bubbles: true,
                cancelable: true,
              }),
            );
          }, isComposing);
          expect(proceeded).toBe(false);
          expect(await sent(page)).toEqual([]);
        }
        await cdp.send("Input.insertText", { text: probe.committed });
        expect(await page.locator(".acpmux-md").textContent()).toBe(probe.committed);
        if (process.env.FAST_CHECKS_OUT) {
          await page.screenshot({
            path: path.join(process.env.FAST_CHECKS_OUT, `ime-${probe.name}-composed.png`),
          });
        }
        await submit(page, probe.committed);
      } finally {
        await cdp.detach();
        await page.close();
      }
    });
  }
});
