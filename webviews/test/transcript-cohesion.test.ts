// l10n-allow-file: synthetic transcript assertions.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-cohesion.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-cohesion";
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "codex-closed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [theme, label] of [["Apple System Colors Light", "light"], ["Catppuccin Mocha", "dark"]]) {
    for (const variant of ["codex-closed", "codex-open", "claude"]) {
      test(`${variant} keeps the activity rhythm (${label})`, async () => {
        const context = await browser.newContext({ viewport: { width: 900, height: 650 }, deviceScaleFactor: 2 });
        const page = await context.newPage();
        try {
          const base = vite.resolvedUrls!.local[0]!.replace(/\/$/, "");
          await page.goto(base + galleryFrame(ENTRY, { variant, theme }), { waitUntil: "networkidle" });
          await page.locator(".cv-md").filter({ hasText: "All three focused tests pass." }).waitFor();
          const headers = page.locator(".acpmux-worked > .cv-worked");
          if (variant === "claude") {
            expect(await headers.count()).toBe(0);
            await page.locator(".cv-tool").filter({ hasText: /Read|Ran|Searched|Used/ }).first().waitFor();
          } else {
            await headers.waitFor();
            await page.waitForFunction((open) =>
              document.querySelector(".acpmux-worked > .cv-worked")?.getAttribute("aria-expanded") === String(open),
              variant === "codex-open");
            const measured = await page.evaluate(() => {
              const header = document.querySelector(".acpmux-worked > .cv-worked")!;
              const row = header.closest(".acpmux-row")!;
              const reply = [...document.querySelectorAll(".acpmux-assistant")].find((node) =>
                node.textContent?.includes("All three focused tests pass."))!;
              const box = header.getBoundingClientRect();
              const next = row.nextElementSibling!.getBoundingClientRect();
              return {
                headerHeight: box.height,
                nextGap: next.top - box.bottom,
                replyGap: reply.getBoundingClientRect().top - box.bottom,
              };
            });
            console.log(`transcript-cohesion ${variant} ${label}: ${JSON.stringify(measured)}`);
            if (process.env.CMUX_COHESION_MEASURE_ONLY !== "1") {
              expect(measured.headerHeight).toBeCloseTo(22, 1);
              if (variant === "codex-closed") expect(measured.replyGap).toBeCloseTo(16, 1);
              else expect(measured.nextGap).toBeCloseTo(0, 1);
            }
          }
          if (process.env.FAST_CHECKS_OUT) {
            await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
            await page.screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `transcript-cohesion-${variant}-${label}.png`) });
          }
        } finally {
          await context.close();
        }
      });
    }
  }
});
