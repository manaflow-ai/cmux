// Long approval commands remain single-line and expose their distinct full paths on hover.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("home-inbox-detail-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const entry = "agent-pane.home-lists";
  const variant = "long-commands";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [280, 560]) {
    for (const colorScheme of ["light", "dark"] as const) {
      test(`${width}px ${colorScheme}: truncated commands expose their full distinct paths`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 900 }, colorScheme });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          const frame = galleryFrame(entry, { variant, colorScheme, frame: "component", width, height: 900 });
          await page.goto(`http://127.0.0.1:${port}${frame}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const details = page.locator(".acpmux-home-inbox-detail");
          const tooltipTexts: (string | null)[] = [];
          for (let index = 0; index < (await details.count()); index++) {
            await details.nth(index).hover();
            await page.waitForFunction((index) => {
              const detail = document.querySelectorAll(".acpmux-home-inbox-detail")[index]!;
              const target = detail.closest("[title], [data-tooltip]");
              const expected = target?.getAttribute("data-tooltip") ?? target?.getAttribute("title");
              const tip = document.querySelector<HTMLElement>(".ui-title-tooltip");
              return tip && !tip.hidden && tip.textContent === expected;
            }, index);
            tooltipTexts.push(await page.locator(".ui-title-tooltip").textContent());
          }
          const commands = await details.evaluateAll((elements) =>
            elements.map((element) => ({
              text: element.textContent,
              hoverText: element.getAttribute("data-tooltip") ?? element.getAttribute("title"),
              clientWidth: element.clientWidth,
              scrollWidth: element.scrollWidth,
              whiteSpace: getComputedStyle(element).whiteSpace,
              overflow: getComputedStyle(element).overflow,
              ellipsis: getComputedStyle(element).textOverflow,
            })),
          );
          // Capture the real shared title tooltip, including where it extends beyond the inbox.
          if (process.env.HOME_INBOX_CAPTURE && width === 280) {
            const output = path.resolve(process.env.HOME_INBOX_CAPTURE);
            await mkdir(output, { recursive: true });
            const clip = await page.evaluate(() => {
              const inbox = document.querySelector(".acpmux-home-inbox")!.getBoundingClientRect();
              const tip = document.querySelector(".ui-title-tooltip")!.getBoundingClientRect();
              const y = Math.max(0, Math.min(inbox.top, tip.top) - 8);
              return {
                x: 0,
                y,
                width: innerWidth,
                height: Math.min(innerHeight, Math.max(inbox.bottom, tip.bottom) + 8) - y,
              };
            });
            await page.screenshot({ path: path.join(output, `${colorScheme}.png`), clip });
            const evidence = { width, colorScheme, commands, tooltipTexts };
            await writeFile(path.join(output, `${colorScheme}.json`), JSON.stringify(evidence, null, 2));
            console.log("HOME_INBOX_EVIDENCE=" + JSON.stringify(evidence));
          }
          expect(commands).toHaveLength(2);
          expect(commands[0]!.text).not.toBe(commands[1]!.text);
          for (const [index, command] of commands.entries()) {
            expect(command.scrollWidth).toBeGreaterThan(command.clientWidth);
            expect(command.whiteSpace).toBe("nowrap");
            expect(command.overflow).toBe("hidden");
            expect(command.ellipsis).toBe("ellipsis");
            expect(tooltipTexts[index]).toBe(command.text);
          }
        } finally {
          await page.close();
        }
      });
    }
  }
});
