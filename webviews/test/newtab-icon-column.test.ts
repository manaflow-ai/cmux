// The New Tab composer's icon column (Leo 2026-11-07, of the folder chip above the composer: "I think
// they should be sort of like center aligned with the bypass permissions symbols"): the folder chip's
// icon, the + glyph and the permission mode's shield share one vertical center line. Measured from the
// gallery (agent-pane.new-tab-icon-column) in Chromium, every arm of iconColumn.experiment.ts at every
// width and look; the shipped arm must hold all three centers within 0.5 px. The numbers and a still
// per case land in webviews/artifacts/newtab-icon-column/.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { newTabIconColumn } from "../src/agent-session/acpmux/newtab/iconColumn.experiment";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Measured = Record<string, number | null>;

await requireBrowserLane("newtab-icon-column.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.new-tab-icon-column";
  const ALL = process.env.NEWTAB_ICON_COLUMN_ALL === "1";
  const ARMS =
    process.env.NEWTAB_ICON_COLUMN_ARMS?.split(",") ??
    (ALL ? Object.keys(newTabIconColumn.arms) : [newTabIconColumn.defaultArm]);
  const STATES = ["no-project", "project", "machine"];
  const WIDTHS = ALL ? [320, 430, 760, 1040] : [320, 760];
  const THEMES = ALL
    ? { light: "Apple System Colors Light", dark: "Apple System Colors" }
    : { dark: "Apple System Colors" };
  const webviews = path.resolve(import.meta.dir, "..");
  const outDir = path.join(webviews, "artifacts", "newtab-icon-column");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const rows: string[] = [];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "project" } });
    mkdirSync(outDir, { recursive: true });
  });
  afterAll(async () => {
    if (rows.length) writeFileSync(path.join(outDir, "centers.tsv"), `${rows.join("\n")}\n`);
    console.log(`newtab-icon-column centers\n${rows.join("\n")}`);
    await browser?.close();
    await vite?.close();
  });

  for (const arm of ARMS)
    for (const state of STATES)
      for (const width of WIDTHS)
        for (const [look, theme] of Object.entries(THEMES))
          test(`${arm} ${state} ${width}px ${look}: folder icon, + and shield share one center`, async () => {
            const page = await browser!.newPage({ viewport: { width, height: 360 }, deviceScaleFactor: 2 });
            try {
              const port = (vite!.httpServer!.address() as { port: number }).port;
              await page.goto(
                `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: state, theme, exp: newTabIconColumn.id, arm })}`,
              );
              await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
                timeout: 60_000,
              });
              await page.evaluate(() => document.fonts.ready);
              await page.evaluate(
                () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
              );
              const m: Measured = await page.evaluate(() => {
                const cx = (element: Element | null | undefined) => {
                  if (!element) return null;
                  const rect = element.getBoundingClientRect();
                  return rect.width === 0 ? null : (rect.left + rect.right) / 2;
                };
                const left = (element: Element | null | undefined) =>
                  element ? element.getBoundingClientRect().left : null;
                const q = (selector: string) => document.querySelector(selector);
                return {
                  folder: cx(
                    q(".nt-above .acpmux-location-leading > .acpmux-location-picker:first-child button > :first-child"),
                  ),
                  plus: cx(q(".nt-box .acpmux-composer-plus svg")),
                  shield: cx(q(".nt-foot .acpmux-access-trigger svg")),
                  composerLeft: left(q(".nt-composer")),
                  stripLeft: left(q(".nt-above .acpmux-composer-strip")),
                  contextLeft: left(q(".nt-above .acpmux-composer-context")),
                  folderButtonLeft: left(
                    q(".nt-above .acpmux-location-leading > .acpmux-location-picker:first-child button"),
                  ),
                  boxLeft: left(q(".nt-box")),
                  plusButtonLeft: left(
                    q(".nt-box .acpmux-composer-plus .acpmux-picker-button, .nt-box .acpmux-composer-plus button"),
                  ),
                  footLeft: left(q(".nt-foot .acpmux-composer-foot")),
                  shieldButtonLeft: left(q(".nt-foot .acpmux-access-trigger")),
                };
              });
              const stem = `${arm}-${state}-${width}-${look}`;
              writeFileSync(path.join(outDir, `${stem}.json`), `${JSON.stringify(m, null, 2)}\n`);
              await page
                .locator(".nt-composer")
                .first()
                .screenshot({ path: path.join(outDir, `${stem}.png`) })
                .catch(() => {});
              const centers = [m.folder, m.plus, m.shield];
              const spread = centers.every((value) => typeof value === "number")
                ? Math.max(...(centers as number[])) - Math.min(...(centers as number[]))
                : Number.NaN;
              rows.push(
                [arm, state, width, look, m.folder, m.plus, m.shield, spread.toFixed(2), JSON.stringify(m)].join("\t"),
              );
              expect(centers.every((value) => typeof value === "number")).toBe(true);
              if (arm === newTabIconColumn.defaultArm) expect(spread).toBeLessThanOrEqual(0.5);
            } finally {
              await page.close();
            }
          });
});
