import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("transcript-rhythm.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "../..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.transcript", { browser, params: { variant: "grid-rhythm" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const width of [480, 1000])
    for (const theme of ["light", "dark"]) {
      test(`${theme} ${width}px: transcript column and block rhythm survive hover`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 900 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript", {
              variant: "grid-rhythm",
              theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
              colorScheme: theme,
            })}`,
          );
          await page.locator('[data-row-id="grid-message"] .cv-md').waitFor();
          await page.evaluate(() => document.fonts.ready);
          const measure = () =>
            page.evaluate(() => {
              const rect = (selector: string) => {
                const el = document.querySelector(selector);
                if (!el) throw new Error(`Missing rhythm element: ${selector}`);
                const r = el.getBoundingClientRect();
                return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, height: r.height };
              };
              const header = rect('[data-row-id="grid-header"] .cv-disclosure__line');
              const message = rect('[data-row-id="grid-message"] .cv-md');
              const group = rect(".acpmux-activity .cv-tools > .cv-tool");
              const live = rect(
                ".acpmux-thinking .cv-worked, .acpmux-working .cv-worked, .acpmux-activityLine .cv-activity",
              );
              const composer = rect(".acpmux-composer-box");
              const headerIcon = rect('[data-row-id="grid-header"] .cv-disclosure__icon');
              const toolIcon = rect(".acpmux-activity .cv-tool__icon");
              const chevron = rect(".acpmux-activity .cv-tool__chevron");
              const copy = rect('[data-row-id="grid-message"] .cv-reply-actions .cv-iconbtn svg');
              const paragraphs = [...document.querySelectorAll('[data-row-id="grid-message"] .cv-md > .cv-p')].map(
                (el) => el.getBoundingClientRect(),
              );
              return {
                header,
                message,
                group,
                live,
                composer,
                headerIcon,
                toolIcon,
                chevron,
                copy,
                gaps: [message.top - header.bottom, group.top - message.bottom, live.top - group.bottom],
                inner: paragraphs[1]!.top - paragraphs[0]!.bottom,
                composerGap: composer.top - live.bottom,
              };
            });
          await page.mouse.move(0, 0);
          const hidden = await measure();
          await page.locator('[data-row-id="grid-message"] .cv-md').hover();
          const shown = await measure();
          console.log(`TRANSCRIPT_RHYTHM ${JSON.stringify({ width, theme, hidden, shown })}`);
          if (process.env.CMUX_RHYTHM_CAPTURES) {
            await page.screenshot({ path: `${process.env.CMUX_RHYTHM_CAPTURES}/${theme}-${width}.png` });
          }
          for (const state of [hidden, shown]) {
            for (const gap of state.gaps) expect(Math.abs(gap - 24), "block gap").toBeLessThanOrEqual(0.5);
            expect(Math.abs(state.inner - 12), "paragraph gap").toBeLessThanOrEqual(0.5);
            expect(Math.abs(state.composerGap - 16), "composer gap").toBeLessThanOrEqual(0.5);
            for (const box of [state.message, state.headerIcon, state.toolIcon, state.live, state.copy]) {
              expect(Math.abs(box.left - state.composer.left), "col-left").toBeLessThanOrEqual(0.5);
            }
            expect(Math.abs(state.chevron.right - state.composer.right), "col-right").toBeLessThanOrEqual(0.5);
          }
          expect(shown).toEqual(hidden);
        } finally {
          await page.close();
        }
      });
    }
});
