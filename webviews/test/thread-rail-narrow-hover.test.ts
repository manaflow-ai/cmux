// l10n-allow-file: test fixture prompts, not shipped UI.
// PROBE: the prompt rail's hover at every pane width, in real Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-rail-narrow-hover.test.ts", async () => {
  setDefaultTimeout(600_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-rail-narrow-hover: skipping (run `bunx playwright install chromium`)");
    describe.skip("thread rail narrow hover", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
    if (out) await mkdir(out, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  const rows = Array.from({ length: 18 }, (_, index) => [
    row(`user-${index + 1}`, "user", `Reply with only the word ok and the number ${index + 1}.`),
    row(`answer-${index + 1}`, "assistant", `ok ${index + 1}\n\nA second paragraph so the turn has some height.`),
    row(`summary-${index + 1}`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ]).flat();

  async function open(width: number, motion: "reduce" | "no-preference"): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width, height: 820 } });
    await page.emulateMedia({ reducedMotion: motion });
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => {
      (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown);
    }, rows);
    await page.waitForSelector('[data-tick="3"]');
    return page;
  }

  const state = (page: Page, x: number, y: number) =>
    page.evaluate(
      ({ x, y }) => {
        const rect = (node: Element | null) => {
          if (!node) return null;
          const r = node.getBoundingClientRect();
          return { l: Math.round(r.left), r: Math.round(r.right), t: Math.round(r.top), b: Math.round(r.bottom) };
        };
        const rail = document.querySelector<HTMLElement>(".acpmux-minimap__rail");
        const at = document.elementFromPoint(x, y);
        return {
          rail: rect(rail),
          strip: rect(document.querySelector(".acpmux-minimap__strip")),
          occluded: rail?.hasAttribute("data-occluded") ?? null,
          hovering: rail?.hasAttribute("data-hovering") ?? null,
          pe: rail ? getComputedStyle(rail).pointerEvents : null,
          active: document.querySelectorAll('[data-tick][data-tone="active"]').length,
          card: document.querySelector(".acpmux-minimap__card") !== null,
          at: at ? `${at.tagName.toLowerCase()}.${String(at.className).split(" ")[0]}` : null,
          scroll: rect(document.querySelector(".acpmux-scroll")),
        };
      },
      { x, y },
    );

  const report: unknown[] = [];
  const failures: string[] = [];
  const WIDTHS = [1280, 900, 700, 560, 480, 420, 360, 320, 280, 240, 200, 160];
  for (const motion of ["no-preference", "reduce"] as const)
    for (const mode of ["fresh", "resized"] as const)
      test(`hover at every width (${mode}, ${motion})`, async () => {
        for (const width of WIDTHS) {
          const page = await open(mode === "fresh" ? width : 1280, motion);
          if (mode === "resized") {
            await page.setViewportSize({ width, height: 820 });
            await page.waitForTimeout(300);
          }
          const tick = await page.evaluate(() => {
            const r = document.querySelector<HTMLElement>('[data-tick="3"]')!.getBoundingClientRect();
            const bar = document.querySelector<HTMLElement>('[data-tick="3"] .acpmux-minimap__bar')!.getBoundingClientRect();
            return { y: r.top + r.height / 2, barLeft: bar.left, barRight: bar.right, left: r.left, right: r.right };
          });
          const rest = await state(page, 0, 0);
          for (const target of [
            { name: "edge", x: 2 },
            { name: "bar", x: Math.round(tick.barLeft + 2) },
          ]) {
            await page.mouse.move(width / 2, tick.y);
            await page.waitForTimeout(400);
            await page.mouse.move(target.x, tick.y, { steps: 16 });
            await page.waitForTimeout(250);
            const after = await state(page, target.x, tick.y);
            const entry = { mode, motion, width, target: target.name, x: target.x, tick, rest, after };
            report.push(entry);
            console.log(JSON.stringify(entry));
            if (!after.card || after.active === 0) failures.push(`${mode}/${motion}/${width}/${target.name}`);
            if (out && (!after.card || after.active === 0))
              await page.screenshot({ path: path.join(out, `${mode}-${motion}-${width}-${target.name}.png`) });
          }
          await page.close();
        }
      });
  test("summary", async () => {
    if (out) await writeFile(path.join(out, "report.json"), JSON.stringify(report, null, 1));
    console.log("FAILURES", JSON.stringify(failures));
    expect(failures).toEqual([]);
  });
});
