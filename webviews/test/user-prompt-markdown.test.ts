// cmux-web-test-timeout: 180
// l10n-allow-file: privacy-safe synthetic prompts, never private session content.
// Leo: "where is the rendering for this :(" — his own sent quote showed raw > lines.
// Leo: "WHY IS THIS RENDERING/MESSAGING NOT FIXED YET" — a delivered review showed literal backticks
// and a SHA range cut mid-hash.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";
import { BUBBLE } from "../src/agent-session/acpmux/transcriptSpacing";

await requireBrowserLane("user-prompt-markdown.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.user-bubble";
  const variant = "markdown-parity";
  // Paired evidence only: replay the same fixture with the base PromptText source installed.
  const plain = process.env.CMUX_USER_MARKDOWN_EXPECT === "plain";
  const capture = process.env.CMUX_USER_MARKDOWN_CAPTURE;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant } });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "markdown-long-tokens" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["dark", "light"]) {
    test(`${colorScheme}: a sent quote and standalone list keep Markdown semantics`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 1000 } });
      try {
        await installPaintedFrames(page);
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(entry, {
            variant,
            frame: "component",
            width: 900,
            height: 1000,
            colorScheme,
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const quote = page.locator('[data-row-id="markdown-quote"] .cv-user__bubble');
        const list = page.locator('[data-row-id="markdown-list"] .cv-user__bubble');
        await quote.waitFor();
        await list.waitFor();
        // Rendered blocks can be taller than ten text lines; reveal the existing disclosure.
        const more = list.locator('.cv-user__more[aria-expanded="false"]');
        if (await more.count()) await more.click();
        await page.evaluate(async () => {
          await document.fonts.ready;
          await window.cmuxPaintFrame();
          await window.cmuxPaintFrame();
        });
        expect(await quote.textContent()).toContain("The uploader retries forever.");
        expect(await list.textContent()).toContain("retry_count");
        const chrome = await quote.evaluate((node) => {
          const style = getComputedStyle(node);
          return {
            padding: style.padding,
            radius: style.borderRadius,
            fontSize: style.fontSize,
            lineHeight: style.lineHeight,
            color: style.color,
            tint: style.getPropertyValue("--glass-tint").trim(),
            width: node.getBoundingClientRect().width,
          };
        });
        // design/transcript-spacing.md "Prompt bubble" (transcriptSpacing.ts BUBBLE): 16 at the
        // sides, a 12 radius, the block padding what a 44 one-line bubble leaves its line.
        expect(chrome.padding).toBe(
          `${(BUBBLE.oneLine - parseFloat(chrome.lineHeight)) / 2}px ${BUBBLE.paddingInline}px`,
        );
        expect(chrome.radius).toBe(`${BUBBLE.radius}px`);
        expect(chrome.width).toBeLessThanOrEqual(630);
        if (plain) {
          expect(await quote.locator("blockquote").count()).toBe(0);
          expect(await quote.textContent()).toContain("> The uploader");
          expect(await list.locator("ol").count()).toBe(0);
        } else {
          expect(await quote.locator("blockquote").count()).toBe(1);
          expect(await quote.textContent()).not.toContain("> The uploader");
          expect(await list.locator("ol > li").count()).toBe(2);
          expect(await list.locator("code.cv-code").textContent()).toBe("retry_count");
          expect(await list.locator("strong").textContent()).toBe("exhausted");
          expect(await list.locator(".cv-codeblock").count()).toBe(1);
          expect(await list.locator('a[href="https://example.com/retry"]').textContent()).toContain("retry guide");
          expect(await list.textContent()).not.toContain("```text");
          const bar = await quote.locator("blockquote").evaluate((node) => {
            const style = getComputedStyle(node, "::before");
            return { width: parseFloat(style.width), background: style.backgroundColor };
          });
          expect(bar.width).toBeGreaterThan(0);
          expect(bar.background).not.toBe("rgba(0, 0, 0, 0)");
        }
        console.log(`USER_MARKDOWN_CHROME ${JSON.stringify({ colorScheme, plain, ...chrome })}`);
        if (capture) {
          mkdirSync(capture, { recursive: true });
          const name = `${plain ? "before" : "after"}-${colorScheme}.png`;
          const png = await page.screenshot();
          writeFileSync(path.join(capture, name), png);
          console.log(`CMUX_SCREENSHOT_SHA256 ${name} ${createHash("sha256").update(png).digest("hex")}`);
          const encoded = png.toString("base64");
          for (let at = 0; at < encoded.length; at += 12_000)
            console.log(`CMUX_SCREENSHOT ${name} ${at} ${encoded.slice(at, at + 12_000)}`);
          console.log(`CMUX_SCREENSHOT_END ${name} ${encoded.length}`);
        }
      } finally {
        await page.close();
      }
    });
  }

  for (const colorScheme of ["dark", "light"]) {
    test(`${colorScheme}: a delivered review renders its code and breaks long tokens only at separators`, async () => {
      const page = await browser.newPage({ viewport: { width: 560, height: 900 } });
      try {
        await installPaintedFrames(page);
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(entry, {
            variant: "markdown-long-tokens",
            frame: "component",
            width: 560,
            height: 900,
            colorScheme,
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const bubble = page.locator('[data-row-id="markdown-long-tokens"] .cv-user__bubble');
        await bubble.waitFor();
        const more = bubble.locator('.cv-user__more[aria-expanded="false"]');
        if (await more.count()) await more.click();
        await page.evaluate(async () => {
          await document.fonts.ready;
          await window.cmuxPaintFrame();
        });
        const text = (await bubble.textContent()) ?? "";
        const layout = await bubble.evaluate((node) => {
          // A text node of hex alone, 8 or more long, drawn on more than one line was cut mid-hash.
          const cut: string[] = [];
          const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
          for (let at = walker.nextNode(); at; at = walker.nextNode()) {
            for (const hex of at.textContent!.matchAll(/[0-9a-f]{8,}/g)) {
              const range = document.createRange();
              range.setStart(at, hex.index!);
              range.setEnd(at, hex.index! + hex[0].length);
              const tops = new Set([...range.getClientRects()].map((rect) => Math.round(rect.top)));
              if (tops.size > 1) cut.push(hex[0]);
            }
          }
          return {
            cut,
            code: [...node.querySelectorAll("code.cv-code")].map((code) => code.textContent),
            wbr: node.querySelectorAll("wbr").length,
            overflow: node.scrollWidth - node.clientWidth,
          };
        });
        if (plain) {
          expect(text).toContain("`repeatsPrompt`");
        } else {
          expect(text).not.toContain("`repeatsPrompt`");
          expect(layout.code).toContain("repeatsPrompt");
          expect(layout.wbr).toBeGreaterThan(0);
          expect(layout.cut).toEqual([]);
        }
        if (!plain) expect(layout.overflow).toBeLessThanOrEqual(1);
        console.log(`USER_MARKDOWN_LONG_TOKENS ${JSON.stringify({ colorScheme, plain, ...layout })}`);
        if (capture) {
          mkdirSync(capture, { recursive: true });
          const name = `${plain ? "before" : "after"}-long-tokens-${colorScheme}.png`;
          const png = await page.screenshot();
          writeFileSync(path.join(capture, name), png);
          console.log(`CMUX_SCREENSHOT_SHA256 ${name} ${createHash("sha256").update(png).digest("hex")}`);
          const encoded = png.toString("base64");
          for (let at = 0; at < encoded.length; at += 12_000)
            console.log(`CMUX_SCREENSHOT ${name} ${at} ${encoded.slice(at, at + 12_000)}`);
          console.log(`CMUX_SCREENSHOT_END ${name} ${encoded.length}`);
        }
      } finally {
        await page.close();
      }
    });
  }
});
