// Every label + chevron control keeps one room between its words and its chevron
// (docs/cmux-next/ui-guidelines.md; Leo, 2026-11-27, on two chips whose chevrons touched their last
// letter: "these chevrons are too close dont we have any guidelines for these yet?").
//
// Measured in Chromium over gallery scenes, at a wide and a narrow width
// (test/support/disclosureChevrons.ts): each chevron's ink starts MIN_GAP to MAX_GAP px after the
// right edge of the last visible words before it (an ellipsis counts where it ends) and is never cut
// by a box around it, a capped label included. Transcript rows have their own, tighter bounds
// (transcript-chevron-after-label.test.ts).
//
// CMUX_CHEVRON_LOG=1 logs every pair measured.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { measureDisclosureChevrons, type ChevronPair } from "./support/disclosureChevrons";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("disclosure-chevron-gap.test.ts", async () => {
  setDefaultTimeout(240_000);
  const MIN_GAP = 3;
  const MAX_GAP = 8;
  const LOG = process.env.CMUX_CHEVRON_LOG === "1";
  /** `pairs`: the fewest label + chevron pairs the scene must show, so a scene that stops drawing its
   *  chips cannot pass by measuring nothing. The gap floor is MIN_GAP for every scene. */
  const SCENES: { entry: string; variant: string; pairs: number }[] = [
    // The shared face: the two chips Leo flagged, redrawn, and one capped at 120px.
    { entry: "ui.disclosure-face", variant: "space-1", pairs: 3 },
    // The composer's chips and pickers (location, access).
    { entry: "agent-pane.composer-any-host", variant: "remote-rest", pairs: 2 },
  ];
  const WIDTHS = [760, 400];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("disclosure chevron gap", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const scene of SCENES)
      await warmGalleryFrame(vite, scene.entry, { browser, params: { variant: scene.variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const measured = new Map<string, ChevronPair[]>();
  const of = async (scene: (typeof SCENES)[number], width: number) => {
    const key = `${scene.entry}#${scene.variant}@${width}`;
    const known = measured.get(key);
    if (known) return known;
    const page = await browser.newPage({ viewport: { width: width + 40, height: 1100 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(scene.entry, { variant: scene.variant, width, reducedMotion: "true" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      const result = await measureDisclosureChevrons(page);
      if (LOG) console.log(`CHEVRONS ${key}\n${result.map((each) => JSON.stringify(each)).join("\n")}`);
      measured.set(key, result);
      return result;
    } finally {
      await page.close();
    }
  };

  for (const scene of SCENES)
    for (const width of WIDTHS) {
      const name = `${scene.entry}#${scene.variant} at ${width}px`;
      test(`${name}: has label + chevron pairs to measure`, async () => {
        expect((await of(scene, width)).length).toBeGreaterThanOrEqual(scene.pairs);
      });
      test(`${name}: every chevron starts ${MIN_GAP}-${MAX_GAP}px after its words, uncut`, async () => {
        const wrong = (await of(scene, width)).filter(
          ({ gap, clipped, kind }) => clipped || kind === "text" || gap < MIN_GAP - 0.5 || gap > MAX_GAP + 0.5,
        );
        expect(wrong).toEqual([]);
      });
    }
});
