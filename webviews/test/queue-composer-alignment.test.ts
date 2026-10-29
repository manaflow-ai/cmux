// The attached queue and its fold continue the composer's surface. A narrow composer widens into
// its gutters; every joined piece must keep the same edges (Leo/Lawrence, ask-a1c7dd28ee).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("queue-composer-alignment.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "queued-long-open" } });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const scrollers of ["overlay", "legacy"])
    for (const look of ["claude", "codex"] as const)
      for (const width of [720, 260])
        for (const scheme of ["light", "dark"] as const)
          test(
            look + ", " + width + "px, " + scheme + ", " + scrollers + ": queue and fold share the box edges",
            async () => {
              const page = await browser.newPage({ viewport: { width, height: 600 } });
              try {
                await page.addInitScript((value) => localStorage.setItem("cmux.composer.look", value), look);
                const port = (vite.httpServer!.address() as { port: number }).port;
                await page.goto(
                  "http://127.0.0.1:" +
                    port +
                    galleryFrame("agent-pane.composer", {
                      variant: "queued-long-open",
                      frame: "component",
                      width,
                      theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
                      colorScheme: scheme,
                    }),
                );
                await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
                await page.waitForSelector(".acpmux-composer-queue[data-unfolded]");
                await page.waitForFunction(
                  (value) =>
                    (document.querySelector(".acpmux-composer")?.getAttribute("data-composer-look") ?? "claude") ===
                    value,
                  look,
                );
                await page.evaluate(() => document.fonts.ready);
                await page.evaluate((mode) => {
                  document.documentElement.dataset.scrollers = mode;
                }, scrollers);
                const problems: string[] = [];
                for (const state of ["expanded", "collapsed"]) {
                  if (state === "collapsed") {
                    await page.locator(".acpmux-queue-fold").click();
                    await page.waitForSelector(".acpmux-composer-queue:not([data-unfolded])");
                  }
                  await page.evaluate(
                    () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
                  );
                  const measured = await page.evaluate(() => {
                    const rect = (selector: string) => {
                      const box = document.querySelector(selector)!.getBoundingClientRect();
                      return { left: box.left, right: box.right, top: box.top, bottom: box.bottom, width: box.width };
                    };
                    return {
                      container: rect(".acpmux-composer"),
                      box: rect(".acpmux-composer-box"),
                      queue: rect(".acpmux-composer-queue"),
                      fold: rect(".acpmux-queue-foldbar"),
                      rows: [...document.querySelectorAll<HTMLElement>(".acpmux-queued")].map((row) => {
                        const text = row.querySelector<HTMLElement>(".acpmux-queued-text")!;
                        const actions = [...row.querySelectorAll<HTMLElement>(".acpmux-queued-action")];
                        const last = actions.at(-1)!.getBoundingClientRect();
                        return {
                          text: text.getBoundingClientRect().left,
                          lastCenter: (last.left + last.right) / 2,
                          height: row.getBoundingClientRect().height,
                        };
                      }),
                      play: (window as Window & { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport,
                    };
                  });
                  // Capture the synthetic fixture before assertions, including both baseline states.
                  const output = process.env.CMUX_ALIGNMENT_CAPTURE_DIR;
                  if (output) {
                    await mkdir(output, { recursive: true });
                    const name = look + "-" + width + "-" + scheme + "-" + scrollers + "-" + state;
                    const png = await page.screenshot({ path: path.join(output, name + ".png") });
                    await writeFile(
                      path.join(output, name + ".json"),
                      JSON.stringify(
                        { ...measured, pngSha256: createHash("sha256").update(png).digest("hex") },
                        null,
                        2,
                      ),
                    );
                  }
                  console.log(JSON.stringify({ look, width, scheme, state, ...measured }));
                  if (measured.container.width <= 260 !== (width === 260))
                    problems.push(`${state}: unexpected container width ${measured.container.width}`);
                  for (const [name, piece] of [
                    ["queue", measured.queue],
                    ["fold", measured.fold],
                  ] as const) {
                    for (const edge of ["left", "right"] as const) {
                      const delta = Math.abs(piece[edge] - measured.box[edge]);
                      if (delta > 0.5) problems.push(`${state}: ${name} ${edge} differs from box by ${delta}px`);
                    }
                  }
                  expect(measured.rows.length).toBeGreaterThan(0);
                  for (const [index, row] of measured.rows.entries()) {
                    if (Math.abs(row.text - measured.box.left - 44) > 0.5)
                      problems.push(
                        `${state}: row ${index} text is ${row.text - measured.box.left}px from left, expected 44`,
                      );
                    if (Math.abs(measured.box.right - row.lastCenter - 22) > 0.5)
                      problems.push(
                        `${state}: row ${index} final action is ${measured.box.right - row.lastCenter}px from right, expected 22`,
                      );
                    if (row.height < 27.5) problems.push(`${state}: row ${index} is shorter than 28px`);
                  }
                  if (measured.fold.top < measured.queue.bottom - 1) problems.push(`${state}: fold overlaps queue`);
                }
                // Assert after both captures so a baseline edge failure does not hide the collapsed case.
                expect(problems).toEqual([]);
              } finally {
                await page.close();
              }
            },
          );
  for (const width of [720, 260])
    for (const scheme of ["light", "dark"])
      test(`trust stack (${width}px, ${scheme}): surface and text share composer lines`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 660 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}` +
              galleryFrame("agent-pane.bottom-stack", {
                variant: "trust-permission-queue",
                width,
                frame: "component",
                theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
                colorScheme: scheme,
              }),
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.waitForSelector(".acpmux-trust-ask");
          await page.evaluate(() => document.fonts.ready);
          await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
          const measured = await page.evaluate(() => {
            const rect = (selector: string) => {
              const box = document.querySelector(selector)!.getBoundingClientRect();
              return { left: box.left, right: box.right, top: box.top, bottom: box.bottom };
            };
            return {
              composer: rect(".acpmux-composer-box"),
              trust: rect(".acpmux-trust-ask"),
              text: rect(".acpmux-trust-ask-text"),
              stackGap: parseFloat(getComputedStyle(document.querySelector(".acpmux-dock")!).paddingTop),
            };
          });
          const output = process.env.CMUX_ALIGNMENT_CAPTURE_DIR;
          if (output) {
            await mkdir(output, { recursive: true });
            const name = `trust-${width}-${scheme}`;
            await page.screenshot({ path: path.join(output, `${name}.png`) });
            await writeFile(path.join(output, `${name}.json`), JSON.stringify(measured, null, 2));
          }
          console.log(JSON.stringify({ width, scheme, ...measured }));
          for (const edge of ["left", "right"] as const)
            expect(Math.abs(measured.trust[edge] - measured.composer[edge]), `trust ${edge}`).toBeLessThanOrEqual(0.5);
          expect(Math.abs(measured.text.left - measured.composer.left - 44), "trust text").toBeLessThanOrEqual(0.5);
          expect(measured.stackGap).toBe(16);
        } finally {
          await page.close();
        }
      });
});
