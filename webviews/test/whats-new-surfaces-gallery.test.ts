// l10n-allow-file: test fixtures.
// a408 (2026-10-22): "make more variations of the changelog / What's New", with Conductor's
// changelog (conductor.build/changelog) as the model. design/whats-new-surfaces-gallery holds the
// designs the user picks from: #1 Today and #2 Readable (the default, u4466) and the Conductor-style
// #7 to #12. Each new design shows all three surfaces, the sidebar's Updated card, the expanded
// notes and the Update Ready list, in light and in dark. Their words select with a drag (and Copy
// copies the selection); a drag fires no button, and the buttons still click.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("whats-new-surfaces-gallery.test.ts", async () => {
  setDefaultTimeout(120_000);
  const gallery = pathToFileURL(
    path.resolve(import.meta.dir, "../../design/whats-new-surfaces-gallery/index.html"),
  ).href;
  const NEW = [7, 8, 9, 10, 11, 12];
  const SURFACES = [".sidebar .card", ".notes", ".pop"] as const;

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    describe(name, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      async function open(theme?: "light" | "dark"): Promise<Page> {
        const page = await browser.newPage({ viewport: { width: 1500, height: 1000 } });
        await page.goto(gallery);
        if (theme) await page.locator(`#theme-${theme}`).click();
        return page;
      }
      const selection = (page: Page) => page.evaluate(() => window.getSelection()?.toString() ?? "");
      const log = (page: Page) => page.locator("#log").innerText();

      test("the gallery has twelve designs, #2 Readable still the only default", async () => {
        const page = await open();
        const numbers = await page
          .locator(".cell")
          .evaluateAll((cells) => cells.map((c) => Number((c as HTMLElement).dataset.design)));
        expect(numbers).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
        const defaults = await page
          .locator(".cell[data-default]")
          .evaluateAll((cells) => cells.map((c) => (c as HTMLElement).dataset.design));
        expect(defaults).toEqual(["2"]);
        await page.close();
      });

      test("each new design shows the sidebar card, the expanded notes and the Update Ready list", async () => {
        const page = await open();
        for (const n of NEW) {
          for (const surface of SURFACES) {
            const box = await page.locator(`.cell[data-design="${n}"] ${surface}`).first().boundingBox();
            expect(box, `#${n} ${surface}`).not.toBeNull();
            expect(box!.height, `#${n} ${surface}`).toBeGreaterThan(40);
          }
          // Conductor's entries are a version and a title, then a date: every surface names the update.
          const notes = await page.locator(`.cell[data-design="${n}"] .notes`).innerText();
          expect(notes, `#${n}`).toMatch(/Oct(ober)? 22/);
        }
        await page.close();
      });

      test("light and dark each paint the gallery in their own scheme, text readable on its surface", async () => {
        const schemes: Record<string, string> = {};
        for (const theme of ["light", "dark"] as const) {
          const page = await open(theme);
          const result = await page.evaluate((numbers) => {
            const rgb = (value: string) => (value.match(/[\d.]+/g) ?? []).slice(0, 3).map(Number);
            const lum = (value: string) => {
              const [r, g, b] = rgb(value).map((c) => {
                const s = c / 255;
                return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
              });
              return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
            };
            const background = (el: Element): string => {
              for (let node: Element | null = el; node; node = node.parentElement) {
                const bg = getComputedStyle(node).backgroundColor;
                const parts = (bg.match(/[\d.]+/g) ?? []).map(Number);
                if (parts.length === 3 || (parts.length === 4 && parts[3]! >= 0.9)) return bg;
              }
              return getComputedStyle(document.body).backgroundColor;
            };
            const worst: Record<string, number> = {};
            for (const n of numbers) {
              const notes = document.querySelector(`.cell[data-design="${n}"] .notes`)!;
              const text = notes.querySelector("h2, h3, li, p")!;
              const a = lum(getComputedStyle(text).color);
              const b = lum(background(text));
              worst[n] = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
            }
            return {
              scheme: document.documentElement.dataset.theme ?? "",
              body: getComputedStyle(document.body).backgroundColor,
              worst,
            };
          }, NEW);
          expect(result.scheme).toBe(theme);
          schemes[theme] = result.body;
          for (const n of NEW) expect(result.worst[n], `#${n} ${theme}`).toBeGreaterThan(4.5);
          await page.close();
        }
        expect(schemes.light).not.toBe(schemes.dark);
      });

      test("the new designs' words select with a drag and fire nothing; their buttons still click", async () => {
        const page = await open();
        for (const n of NEW) {
          for (const surface of SURFACES) {
            const text = page.locator(`.cell[data-design="${n}"] ${surface} li`).first();
            await text.scrollIntoViewIfNeeded();
            const box = (await text.boundingBox())!;
            const y = box.y + Math.min(8, box.height / 2);
            await page.mouse.move(box.x + 2, y);
            await page.mouse.down();
            await page.mouse.move(box.x + box.width / 2, y, { steps: 4 });
            await page.mouse.move(box.x + box.width - 2, y, { steps: 4 });
            await page.mouse.up();
            expect((await selection(page)).trim().length, `#${n} ${surface}`).toBeGreaterThan(3);
            expect(await log(page), `#${n} ${surface}`).not.toContain("clicked");
          }
          await page.locator(`.cell[data-design="${n}"] .card [data-act]:not(.x)`).first().click();
          expect(await log(page)).toContain(`#${n}: clicked`);
          await page.locator("#log").evaluate((el) => (el.textContent = ""));
        }
        await page.close();
      });
    });
  }
});
