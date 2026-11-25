// The suite behind test/browser/golden-look-contrast-{0,1,2,3}.test.ts, split four ways so each file
// stays under its time limit (405 stages at about 3.7 s on the CI runner, 2026-11-23).
//
// The golden screen is the sample every look is checked on (Leo, 2026-11-19: "take stills from a
// representative state" and "you guys also need to watch for if there's light on light or dark on
// dark"). The gallery's looks.golden entry (src/gallery/golden/golden.gallery.ts: one chat with every
// part a look changes) and looks.golden-menus (its open menu, submenu and usage popover) are drawn under
// every look the checkout carries: the registry
// (src/gallery/golden/looks.json), each shipped theme file, each look pack setup folder and theme file
// under examples/ (dev-server/goldenLooks.ts discoverLooks, found rather than listed, so a new look is
// checked without touching this file), in each scheme it draws. contrastWalk.ts reads every
// drawn line of text and icon: WCAG AA, 4.5:1 for text, 3:1 for large text and icons. A failure names
// the look, scheme, element, text, foreground, background, ratio and minimum.
//
// The known pairs (contrastKnown.ts) are reported and pass; any other pair fails. Captures go to $FAST_CHECKS_OUT/golden-look-contrast.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { belowMinimum, distinctPairs, formatPair, readContrast } from "./contrastWalk";
import { goldenKnownFor } from "./contrastKnown";
import { galleryFrame, warmGalleryFrame } from "./galleryFrame";

/**
 * Registers the golden screen's stages for shard `shard` of `shards` (0-based): every look whose index in the
 * list is `shard` modulo `shards`, so a new look lands in one shard and the four stay about even. Shard 0 also
 * checks the list itself. Called inside requireBrowserLane by each golden-look-contrast-N.test.ts.
 */
export async function goldenLookContrastSuite(shard: number, shards: number): Promise<void> {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "../..");
  const out = process.env.FAST_CHECKS_OUT ? path.join(process.env.FAST_CHECKS_OUT, "golden-look-contrast") : null;
  if (out) mkdirSync(out, { recursive: true });

  // The gallery's looks module (virtual:cmux-gallery/looks) and this list read the same switch.
  process.env.CMUX_GOLDEN_EVERY_LOOK = "1";
  const { discoverLooks, drawnSchemes, readGoldenLooks } = await import("../../dev-server/goldenLooks");
  const { looks: every, skipped } = readGoldenLooks([]);
  if (shard === 0) for (const skip of skipped) console.log(`golden-look-contrast: skipped ${skip.id}: ${skip.reason}`);
  const looks = every.filter((_, index) => index % shards === shard);
  /** The golden screen's two stages: the chat, and its menus and popover (which portal outside it). */
  const SCREENS = [
    // Tall enough that the whole chat is on screen: a line scrolled out of view is not read.
    { entry: "looks.golden", name: "chat", ready: ".cv-user__bubble", atLeast: 30, height: 3200 },
    { entry: "looks.golden-menus", name: "menus", ready: ".acpmux-plan-usage", atLeast: 12, height: 700 },
  ] as const;

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
    for (const screen of SCREENS)
      await warmGalleryFrame(vite, screen.entry, { browser, params: { variant: looks[0]!.id } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  if (shard === 0) {
    test("every look the checkout carries is checked (shipped theme files, examples/, the registry)", () => {
      const ids = new Set(every.map((look) => look.source));
      const missing = discoverLooks()
        .map((look) => look.source)
        .filter((source) => !ids.has(source));
      expect(missing).toEqual([]);
      expect(every.some((look) => look.source.startsWith("Resources/theme-files/"))).toBe(true);
    });
  }

  for (const look of looks) {
    for (const scheme of drawnSchemes(look)) {
      for (const screen of SCREENS) {
        test(`${look.id} (${scheme}, ${look.source}): every line of the golden ${screen.name} meets WCAG AA`, async () => {
          const page = await browser.newPage({ viewport: { width: 1000, height: screen.height } });
          try {
            const port = (vite.httpServer!.address() as { port: number }).port;
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(screen.entry, {
                variant: look.id,
                theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
                colorScheme: scheme,
              })}`,
            );
            await page.waitForFunction(() => !!document.documentElement.dataset.galleryReady, undefined, {
              timeout: 90_000,
            });
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            await page.locator(screen.ready).first().waitFor();
            await page.evaluate(() => document.fonts.ready.then(() => undefined));
            // Fades end before the read: every finite animation and transition is run to its end, and
            // two frames paint the settled colors. The pointer stays where the play left it (an open
            // submenu stays open).
            await page.evaluate(async () => {
              const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
              await frame();
              for (const animation of document.getAnimations())
                if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
              await frame();
              await frame();
            });
            const lines = await readContrast(page);
            // The screen drew what it holds (the chat: prompts, reply, tool rows, permission, composer;
            // the menus: both menus' rows and the popover's).
            expect(lines.length).toBeGreaterThanOrEqual(screen.atLeast);
            const failing = distinctPairs(belowMinimum(lines));
            if (out) {
              const name = `${look.id}-${scheme}-${screen.name}`;
              writeFileSync(path.join(out, `${name}.json`), JSON.stringify(lines, null, 1));
              writeFileSync(path.join(out, `${name}.png`), await page.screenshot({ fullPage: true }));
            }
            for (const line of failing.filter((line) => goldenKnownFor(line, look.id)))
              console.log(`golden-look-contrast KNOWN ${look.id} ${scheme} ${screen.name}: ${formatPair(line)}`);
            const unexpected = failing
              .filter((line) => !goldenKnownFor(line, look.id))
              .map((line) => `${look.id} ${scheme} ${screen.name} (${look.source}): ${formatPair(line)}`);
            console.log(
              `golden-look-contrast ${look.id} ${scheme} ${screen.name}: ${lines.length} lines, ${failing.length} under the minimum, ${unexpected.length} not known`,
            );
            expect(unexpected).toEqual([]);
          } finally {
            await page.close();
          }
        });
      }
    }
  }
}
