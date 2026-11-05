// l10n-allow-file: browser measurements and fixture labels, not shipped UI.
// Same-harness comparison: copy this test and browser/status-verbs.{html,harness.tsx} to base,
// then set STATUS_VERBS_BASELINE=1. Both revisions print measured labels and elapsed displacement
// across the same 0..24s injected timeline. A separate test exercises actual shared-clock ticks.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import type {} from "./browser/status-verbs.harness";
import { THINKING_VERBS, thinkingVerb } from "../src/agent-session/acpmux/conversation/thinkingVerbs";

await requireBrowserLane("status-verbs-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("status-verbs", "chromium", chromium))) return;
  setDefaultTimeout(120_000);
  const baseline = process.env.STATUS_VERBS_BASELINE === "1";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    const webviews = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/status-verbs.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  const open = async () => {
    const page = await browser.newPage({
      viewport: { width: 760, height: 1200 },
      deviceScaleFactor: 2,
    });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/status-verbs.html`);
    await page.waitForFunction(() => Boolean(window.__statusVerbs));
    await page.evaluate(async () => {
      await window.__statusVerbs.ready;
      await document.fonts.ready;
    });
    return page;
  };
  const sample = (page: Page) =>
    page.evaluate(async () => {
      await window.cmuxPaintFrame();
      return Array.from(document.querySelectorAll(".cv-worked"), (row) => ({
        label: row.querySelector(".cv-shimmer__base")?.textContent ?? "",
        timeX: row.querySelector(".cv-worked__time")!.getBoundingClientRect().x,
        height: row.getBoundingClientRect().height,
        rowX: row.getBoundingClientRect().x,
        rowY: row.getBoundingClientRect().y,
        rowWidth: row.getBoundingClientRect().width,
        shimmerOffset: Math.abs(
          row.querySelector(".cv-shimmer__lit-time")!.getBoundingClientRect().x -
            row.querySelector(".cv-worked__time")!.getBoundingClientRect().x,
        ),
      }));
    });

  for (const count of [1, 20])
    test(`${count} rows: rendered labels and elapsed displacement over 24s`, async () => {
      const page = await open();
      try {
        const labels = new Set<string>();
        const positions: number[][] = Array.from({ length: count }, () => []);
        const heights = new Set<number>();
        const geometry: Array<Array<{ x: number; y: number; width: number }>> = Array.from({ length: count }, () => []);
        let shimmerOffset = 0;
        for (let elapsed = 0; elapsed <= 24_000; elapsed += 1_000) {
          await page.evaluate(({ count, elapsed }) => window.__statusVerbs.show(count, elapsed), {
            count,
            elapsed,
          });
          const rows = await sample(page);
          expect(rows).toHaveLength(count);
          rows.forEach((row, index) => {
            expect(row.label).not.toBe("");
            labels.add(row.label);
            positions[index]!.push(row.timeX);
            geometry[index]!.push({ x: row.rowX, y: row.rowY, width: row.rowWidth });
            heights.add(row.height);
            shimmerOffset = Math.max(shimmerOffset, row.shimmerOffset);
          });
        }
        const displacement = Math.max(...positions.map((xs) => Math.max(...xs) - Math.min(...xs)));
        const clocks = await page.evaluate(() => window.__statusVerbs.clocks());
        console.log(
          JSON.stringify({
            harness: "status-verbs-mounted-24s",
            baseline,
            count,
            distinctLabels: labels.size,
            labels: [...labels],
            elapsedDisplacementPx: displacement,
            shimmerOffsetPx: shimmerOffset,
            sharedClocks: clocks.running,
            subscribers: clocks.subscribers,
            heights: [...heights],
            rowGeometry: positions.map((xs, index) => ({
              index,
              timerRange: [Math.min(...xs), Math.max(...xs)],
              rowX: [...new Set(geometry[index]!.map((rect) => rect.x))],
              rowY: [...new Set(geometry[index]!.map((rect) => rect.y))],
              widths: [...new Set(geometry[index]!.map((rect) => rect.width))],
            })),
          }),
        );
        // Each chat has its own 336px content box (360px fixture minus 24px padding), stacked
        // vertically. The shell itself defaults to a horizontal flex row; that is not 20 chats.
        for (const [index, frames] of geometry.entries()) {
          expect(new Set(frames.map((rect) => rect.width))).toEqual(new Set([336]));
          expect(new Set(frames.map((rect) => rect.x))).toEqual(new Set([geometry[0]![0]!.x]));
          expect(new Set(frames.map((rect) => rect.y)).size).toBe(1);
          if (index > 0) expect(frames[0]!.y).toBeGreaterThan(geometry[index - 1]![0]!.y);
        }
        expect(labels.size).toBe(1);
        expect(displacement).toBeLessThanOrEqual(0.5);
        expect(heights.size).toBe(1);
        expect(shimmerOffset).toBeLessThanOrEqual(0.5);
        expect(clocks.running).toBe(1);
        expect(clocks.subscribers).toBe(count);
        await page.evaluate(() => window.__statusVerbs.hidden(true));
        expect(await page.evaluate(() => window.__statusVerbs.clocks().running)).toBe(0);
        await page.evaluate(() => window.__statusVerbs.hidden(false));
        expect(await page.evaluate(() => window.__statusVerbs.clocks().running)).toBe(1);
        await page.evaluate(() => window.__statusVerbs.clear());
        expect(await page.evaluate(() => window.__statusVerbs.clocks())).toMatchObject({
          running: 0,
          subscribers: 0,
        });
      } finally {
        await page.close();
      }
    });

  if (!baseline)
    test("real clock rotates, settings switch in place, and long custom labels keep the timer in bounds", async () => {
      const page = await open();
      const rotatingVerb = thinkingVerb(THINKING_VERBS, "status-verbs")!;
      try {
        await page.evaluate(() => window.__statusVerbs.mode("rotate"));
        await page.evaluate(() => window.__statusVerbs.show(1));
        expect((await sample(page))[0]!.label).toBe(rotatingVerb);
        await page.evaluate(() => window.__statusVerbs.mode("thinking"));
        expect((await sample(page))[0]!.label).toBe("Thinking");
        await page.evaluate(() => window.__statusVerbs.mode("custom", "Imagining"));
        expect((await sample(page))[0]!.label).toBe("Imagining");
        const long = "Considering every possibility ".repeat(30).trim();
        const xs: number[] = [];
        for (const elapsed of [0, 2400, 4800]) {
          await page.evaluate(
            ({ long, elapsed }) => {
              window.__statusVerbs.mode("custom", `Reading,${long},Testing`);
              window.__statusVerbs.show(1, elapsed);
            },
            { long, elapsed },
          );
          xs.push((await sample(page))[0]!.timeX);
          const fits = await page.evaluate(() => {
            const time = document.querySelector(".cv-worked__time")!.getBoundingClientRect();
            const row = document.querySelector(".cv-worked")!.getBoundingClientRect();
            return time.right <= row.right + 0.5;
          });
          expect(fits).toBe(true);
        }
        expect(Math.max(...xs) - Math.min(...xs)).toBeLessThanOrEqual(0.5);
      } finally {
        await page.close();
      }
    });

  if (!baseline)
    test("interactive gallery: all modes and light/dark captures", async () => {
      const page = await open();
      try {
        const output = process.env.FAST_CHECKS_OUT;
        if (output) await mkdir(output, { recursive: true });
        for (const variant of ["rotating", "thinking-only", "custom"]) {
          await page.evaluate((variant) => window.__statusVerbs.gallery(variant), variant);
          await page.getByRole("combobox", { name: "Working status" }).waitFor();
          for (const theme of ["light", "dark"] as const) {
            await page.evaluate((theme) => window.__statusVerbs.theme(theme), theme);
            await page.evaluate(() => window.cmuxPaintFrame());
            if (output)
              await page
                .locator("[data-status-verbs-gallery]")
                .screenshot({ path: path.join(output, `status-verbs-${variant}-${theme}.png`) });
          }
        }
        await page.getByRole("textbox", { name: "Custom verbs" }).fill("Imagining");
        expect((await sample(page))[0]!.label).toBe("Imagining");
        await page.getByRole("combobox", { name: "Working status" }).selectOption("thinking");
        expect((await sample(page))[0]!.label).toBe("Thinking");
        await page.getByRole("combobox", { name: "Working status" }).selectOption("rotate");
        const first = (await sample(page))[0]!.label;
        await page.waitForFunction(
          (first) => document.querySelector(".cv-shimmer__base")?.textContent !== first,
          first,
        );
      } finally {
        await page.close();
      }
    });
});
