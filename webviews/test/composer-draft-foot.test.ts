// cmux-web-test-timeout: 600
// l10n-allow-file: test labels, not shipped UI.
// The foot of a long draft scrolled up inside the composer (draftFoot.experiment.ts, markdownField.css).
// Leo, 2026-11-22, paraphrased: too much solid and blur at the bottom of the box; show more there,
// keep some blur, get rid of that bottom band.
//
// Real gallery frames (agent-pane.draft-foot, one variant per arm), the draft scrolled a third down.
// For every arm it sums the draft's ink (the frame against the same frame with the draft hidden) in
// the field's bottom 18 px, the band the shipped mask faded to nothing, and in the 18 px over it.
// The shipping arm must keep more ink than the before in that band, at least 1.3x its ink in
// the last 6 px against the rim, and keep some fade: less ink than the hard edge. With FAST_CHECKS_OUT or CMUX_DRAFT_FOOT_CAPTURE set, it writes foot.json and
// 2x stills of the box for every arm, light and dark.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { COMPOSER_MD_FIELD } from "../src/agent-session/acpmux/composerSelectors";
import { draftFoot } from "../src/agent-session/acpmux/draftFoot.experiment";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Foot = { foot: number; above: number; edge: number; ratio: number };

await requireBrowserLane("composer-draft-foot.test.ts", async () => {
  setDefaultTimeout(560_000);
  const ENTRY = "agent-pane.draft-foot";
  const out = process.env.CMUX_DRAFT_FOOT_CAPTURE ?? process.env.FAST_CHECKS_OUT;
  const ARMS = Object.keys(draftFoot.arms);
  const SCALE = 2;
  const WIDTH = 760;
  const HEIGHT = 640;
  const BAND = 18;
  const EDGE = 6;
  const THEMES = [
    ["Apple System Colors", "dark", undefined],
    ["Apple System Colors Light", "light", undefined],
    ["Apple System Colors", "art-dark", "dark"],
  ] as const;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const record: Record<string, Foot> = {};

  beforeAll(async () => {
    if (out) mkdirSync(path.join(out, "foot"), { recursive: true });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    if (out) writeFileSync(path.join(out, "foot", "foot.json"), JSON.stringify(record, null, 2));
    console.log(`draft-foot: ${JSON.stringify(record)}`);
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, theme: string, background?: string): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: SCALE });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: WIDTH, theme, background })}`);
    await page.locator(`${COMPOSER_MD_FIELD}[data-fade-bottom]`).first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  }

  async function measure(page: Page, still?: string): Promise<Foot> {
    const geometry = await page.evaluate((fieldSelector) => {
      const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      const field = document.querySelector(fieldSelector)!.getBoundingClientRect();
      return {
        box: { x: box.left, y: box.top, width: box.width, height: box.height },
        field: { left: field.left, right: field.right, bottom: field.bottom },
      };
    }, COMPOSER_MD_FIELD);
    if (still) await page.screenshot({ path: still, clip: geometry.box, animations: "disabled", caret: "hide" });
    const clip = {
      x: geometry.field.left,
      y: geometry.field.bottom - 2 * BAND,
      width: geometry.field.right - geometry.field.left - 12,
      height: 2 * BAND,
    };
    const shot = async () => PNG.sync.read(await page.screenshot({ clip, animations: "disabled", caret: "hide" }));
    const shown = await shot();
    await page.addStyleTag({ content: ".acpmux-md-field .ProseMirror { visibility: hidden !important; }" });
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const hidden = await shot();
    const ink = (from: number, to: number) => {
      let sum = 0;
      for (let y = from; y < to; y++)
        for (let x = 0; x < shown.width; x++) {
          const at = (y * shown.width + x) * 4;
          sum +=
            Math.abs(shown.data[at]! - hidden.data[at]!) +
            Math.abs(shown.data[at + 1]! - hidden.data[at + 1]!) +
            Math.abs(shown.data[at + 2]! - hidden.data[at + 2]!);
        }
      return sum / 1000;
    };
    const above = ink(0, BAND * SCALE);
    const foot = ink(BAND * SCALE, shown.height);
    // The field's last 6 px, against the rim: where the shipped mask reached nothing.
    const edge = ink(shown.height - EDGE * SCALE, shown.height);
    return { foot, above, edge, ratio: above > 0 ? foot / above : 0 };
  }

  test("every arm: the draft's ink in the box's foot", async () => {
    for (const arm of ARMS)
      for (const [theme, name, background] of THEMES) {
        const page = await open(arm, theme, background);
        record[`${arm}-${name}`] = await measure(page, out ? path.join(out, "foot", `${arm}-${name}.png`) : undefined);
        await page.close();
      }
    for (const [, name] of THEMES) {
      const before = record[`shipped-${name}`]!;
      const chosen = record[`${draftFoot.defaultArm}-${name}`]!;
      const hard = record[`clip-${name}`]!;
      // Same draft, same scroll: the band over the foot reads the same in every arm.
      expect(Math.abs(chosen.above - before.above)).toBeLessThan(before.above * 0.1 + 1);
      // The shipping foot shows the draft there, down to the rim (Leo: "more stuff there") ...
      expect(chosen.foot).toBeGreaterThan(before.foot * 1.1);
      expect(chosen.edge).toBeGreaterThan(before.edge * 1.3);
      // ... and still softens it (Leo: "we do want some blur").
      expect(chosen.foot).toBeLessThan(hard.foot);
    }
  });
});
