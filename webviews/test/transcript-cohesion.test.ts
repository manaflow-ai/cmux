// cmux-web-test-timeout: 480
// l10n-allow-file: synthetic transcript assertions.
//
// The live-tools cases test the `runs` arm of live-turn-work, not the shipped `line` arm: the row over
// the live line is a finished call of a turn that still runs, which only `runs` draws
// (support/liveTurnRuns.ts). The other cases take the shipped arms.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { pinLiveTurnRuns } from "./support/liveTurnRuns";
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

  for (const [theme, label] of [
    ["Apple System Colors Light", "light"],
    ["Catppuccin Mocha", "dark"],
  ]) {
    for (const density of ["compact", "comfortable"])
      for (const interfaceScale of [1, 1.25])
        for (const variant of ["codex-turn-command-under-messages", "codex-turn-raw-commands"]) {
          test(`${variant} passes live-line gallery play (${label}, ${density}, ${interfaceScale})`, async () => {
            const context = await browser.newContext({ viewport: { width: 900, height: 650 }, deviceScaleFactor: 2 });
            const page = await context.newPage();
            try {
              const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
              await page.goto(
                base +
                  galleryFrame("agent-pane.transcript", {
                    variant,
                    theme,
                    density,
                    interfaceScale,
                    reducedMotion: "true",
                  }),
              );
              await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined);
              expect(
                await page.getAttribute("html", "data-gallery-ready"),
                await page.locator("body").innerText(),
              ).toBe("1");
              if (process.env.FAST_CHECKS_OUT) {
                await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
                await page.screenshot({
                  path: path.join(
                    process.env.FAST_CHECKS_OUT,
                    `thinking-gap-existing-${variant}-${label}-${density}-${interfaceScale}.png`,
                  ),
                });
              }
            } finally {
              await context.close();
            }
          });
        }
    for (const density of ["compact", "comfortable"])
      for (const interfaceScale of [1, 1.25])
        for (const variant of ["live-peers", "live-tools", "live-status"]) {
          test(`${variant} separates live state (${label}, ${density}, ${interfaceScale})`, async () => {
            const context = await browser.newContext({ viewport: { width: 900, height: 650 }, deviceScaleFactor: 2 });
            const page = await context.newPage();
            try {
              const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
              if (variant === "live-tools") await pinLiveTurnRuns(page);
              await page.goto(
                base + galleryFrame(ENTRY, { variant, theme, density, interfaceScale, reducedMotion: "true" }),
                {
                  waitUntil: "networkidle",
                },
              );
              await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
              await page.locator(".acpmux-thinking .cv-worked").waitFor();
              await page.evaluate(() => document.fonts.ready);
              const measured = await page.evaluate(() => {
                const live = document.querySelector(".acpmux-thinking .cv-worked")!;
                let previous = live.closest(".acpmux-row")!.previousElementSibling;
                while (previous && previous.getBoundingClientRect().height === 0)
                  previous = previous.previousElementSibling;
                if (!previous) throw new Error("The live state has no preceding activity row");
                return {
                  gap: live.getBoundingClientRect().top - previous.getBoundingClientRect().bottom,
                  // Read a resolved token rather than parsing a calc() or var() expression.
                  scale: Number.parseFloat(
                    getComputedStyle(document.documentElement).getPropertyValue("--cmux-interface-scale"),
                  ),
                  wholeTurnFolds: document.querySelectorAll(".acpmux-worked").length,
                };
              });
              const phase = process.env.CMUX_GAP_PHASE ?? "after";
              console.log(
                `transcript-live-gap ${phase} ${variant} ${label} ${density} ${interfaceScale}: ${JSON.stringify(measured)}`,
              );
              if (process.env.CMUX_COHESION_MEASURE_ONLY !== "1")
                // The transcript's run gap, 12 at scale 1 (transcriptGrid.ts TRANSCRIPT_RUN_GAP; Lucas, 2026-11-11).
                expect(measured.gap).toBeCloseTo(12 * interfaceScale, 1);
              expect(measured.wholeTurnFolds).toBe(0);
              if (process.env.FAST_CHECKS_OUT) {
                await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
                await page.screenshot({
                  path: path.join(
                    process.env.FAST_CHECKS_OUT,
                    `thinking-gap-${phase}-${variant}-${label}-${density}-${interfaceScale}.png`,
                  ),
                });
              }
            } finally {
              await context.close();
            }
          });
        }
    test(`a paused closing fold keeps layout gap validation (${label})`, async () => {
      const context = await browser.newContext({ viewport: { width: 760, height: 800 } });
      const page = await context.newPage();
      try {
        const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
        await page.goto(base + galleryFrame("agent-pane.transcript", { variant: "worked-for-closing", theme }), {
          waitUntil: "networkidle",
        });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const read = () =>
          page.evaluate(() => ({
            paused: document.getAnimations().filter((animation) => animation.playState === "paused").length,
            gaps: window.cmuxGalleryInvariants?.().filter((item) => item.rule === "gap-token") ?? [],
          }));
        const held = await read();
        expect(held.paused).toBeGreaterThan(0);
        expect(held.gaps).toEqual([]);
        // A real layout error must still fail while the fold is paused: the check does not skip
        // moving rows or widen their token budget.
        await page.evaluate(() => {
          const reply = document.querySelector<HTMLElement>('[data-row-id="gallery-turnfold-answer"]')!;
          reply.style.marginTop = `${Number.parseFloat(getComputedStyle(reply).marginTop) + 3}px`;
        });
        expect((await read()).gaps.some((item) => item.key.includes("gallery-turnfold-answer"))).toBe(true);
      } finally {
        await context.close();
      }
    });
    for (const variant of ["codex-closed", "codex-open", "claude"]) {
      test(`${variant} keeps the activity rhythm (${label})`, async () => {
        const context = await browser.newContext({
          viewport: { width: 900, height: 650 },
          deviceScaleFactor: 2,
        });
        const page = await context.newPage();
        // The claude variant measures Claude's in-place runs (claudeTurnFold.experiment.ts arm
        // "runs"); by default a Claude turn folds under Worked for, as Codex's does.
        if (variant === "claude")
          await page.addInitScript(() => {
            globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "claude-turn-fold": "runs" };
          });
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(String(error)));
        try {
          const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
          await page.goto(base + galleryFrame(ENTRY, { variant, theme, reducedMotion: "true" }), {
            waitUntil: "networkidle",
          });
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, {
            timeout: 30_000,
          });
          expect(await page.getAttribute("html", "data-gallery-ready")).toBe("1");
          await page.evaluate(() => document.fonts.ready);
          await page
            .locator(".acpmux-assistant .cv-p")
            .filter({ hasText: "All three focused tests pass." })
            .waitFor({ timeout: 10_000 });
          const headers = page.locator(".acpmux-worked > .cv-worked");
          if (variant === "claude") {
            expect(await headers.count()).toBe(0);
            await page
              .locator(".cv-tool")
              .filter({ hasText: /Read|Ran|Searched|Used/ })
              .first()
              .waitFor();
          } else {
            await headers.waitFor();
            await page.waitForFunction(
              (open) =>
                document.querySelector(".acpmux-worked > .cv-worked")?.getAttribute("aria-expanded") === String(open),
              variant === "codex-open",
            );
            const measured = await page.evaluate(() => {
              const header = document.querySelector(".acpmux-worked > .cv-worked")!;
              const row = header.closest(".acpmux-row")!;
              const reply = [...document.querySelectorAll(".acpmux-assistant")].find((node) =>
                node.textContent?.includes("All three focused tests pass."),
              )!;
              // Visible text marks, as the shared spacing table measures them; keep row-box
              // checks too, so the estimate cannot hide a different rendered line height.
              const firstLineCenter = (element: Element) => {
                const range = document.createRange();
                range.selectNodeContents(element);
                const rect = range.getClientRects()[0]!;
                return (rect.top + rect.bottom) / 2;
              };
              const box = header.getBoundingClientRect();
              const next = row.nextElementSibling!.getBoundingClientRect();
              return {
                headerHeight: box.height,
                nextGap: next.top - box.bottom,
                replyGap: reply.getBoundingClientRect().top - box.bottom,
                replyCenterGap:
                  firstLineCenter(reply.querySelector(".cv-md p")!) -
                  firstLineCenter(header.querySelector(".cv-worked__label")!),
              };
            });
            console.log(`transcript-cohesion ${variant} ${label}: ${JSON.stringify(measured)}`);
            if (process.env.CMUX_COHESION_MEASURE_ONLY !== "1") {
              // Worked for's rule sits between its words and the next row, open or closed:
              // 4 under its 22px line, 8 over the next row, and no stack gap after it (Codex parity,
              // Lucas, 2026-11-07; conversation.css `.cv-worked.has-divider.is-toggle`, model.ts
              // WORKED_GAP_PT, transcriptGrid.ts MARK_WORKED).
              expect(measured.headerHeight).toBeCloseTo(22 + 4, 1);
              if (variant === "codex-closed") {
                expect(measured.replyGap).toBeCloseTo(8, 1);
                expect(Math.abs(measured.replyCenterGap - 34.375)).toBeLessThan(1);
              } else expect(measured.nextGap).toBeCloseTo(8, 1);
            }
          }
          if (process.env.FAST_CHECKS_OUT) {
            await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
            await page.screenshot({
              path: path.join(process.env.FAST_CHECKS_OUT, `transcript-cohesion-${variant}-${label}.png`),
            });
          }
        } catch (error) {
          console.error(`transcript-cohesion ${variant} ${label}: ${errors.join("\n")}`);
          console.error(await page.locator("body").innerText());
          if (process.env.FAST_CHECKS_OUT) {
            await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
            const prefix = path.join(process.env.FAST_CHECKS_OUT, `failure-${variant}-${label}`);
            await page.screenshot({ path: `${prefix}.png` });
            await writeFile(`${prefix}.html`, await page.content());
          }
          throw error;
        } finally {
          await context.close();
        }
      });
    }
  }
});
