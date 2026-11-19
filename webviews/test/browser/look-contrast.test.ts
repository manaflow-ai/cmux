// Every built-in chat look draws readable text, in light and in dark (Leo, 2026-11-19: "you guys also
// need to watch for if there's light on light or dark on dark"). Each scene opens a gallery stage in
// the app's default theme pair (Apple System Colors Light / Apple System Colors) and reads every drawn
// line of text and icon with support/contrastWalk.ts: WCAG AA, 4.5:1 for text, 3:1 for large text and
// for icons. A failure names the look, theme, element, text, foreground, background, ratio and minimum.
//
// Scenes: the composer in its two looks (claude, codex), empty (placeholder, mode and model row) and
// with a draft (the Send button live); the default transcript with a prompt bubble, tool rows, a peer
// message card, a link, a permission card, and an opened tool run.
//
// KNOWN (support/contrastKnown.ts) lists the pairs the shipping default draws under the minimum today, each with its reason; a
// pair that is not in it fails the test, and a KNOWN pair that no longer fails fails it too, so the
// list only shrinks. Captures go to $FAST_CHECKS_OUT/look-contrast when it is set.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { belowMinimum, distinctPairs, formatPair, readContrast } from "../support/contrastWalk";
import { KNOWN, knownFor, type Known } from "../support/contrastKnown";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("look-contrast.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "../..");
  const out = process.env.FAST_CHECKS_OUT ? path.join(process.env.FAST_CHECKS_OUT, "look-contrast") : null;
  if (out) mkdirSync(out, { recursive: true });

  const COMPOSER = "agent-pane.composer-look";
  const TRANSCRIPT = "agent-pane.transcript";

  type Theme = "light" | "dark";
  type Scene = {
    look: string;
    entry: string;
    variant: string;
    /** What the scene waits for before it reads. */
    ready: string;
    /** Something to do after it loads (type a draft, open a run). */
    act?: (page: Page) => Promise<void>;
    /** At least this many lines are read (the scene drew what it means to check). */
    atLeast: number;
  };
  const typeDraft = async (page: Page) => {
    await page.locator('.acpmux-composer [contenteditable="true"]').first().click();
    await page.keyboard.type("Also cover the 503 path");
  };
  const SCENES: Scene[] = [
    { look: "claude", entry: COMPOSER, variant: "claude-chat", ready: ".acpmux-composer", atLeast: 6 },
    {
      look: "claude+draft",
      entry: COMPOSER,
      variant: "claude-chat",
      ready: ".acpmux-composer",
      act: typeDraft,
      atLeast: 6,
    },
    { look: "codex", entry: COMPOSER, variant: "codex-chat", ready: '[data-composer-look="codex"]', atLeast: 6 },
    {
      look: "codex+draft",
      entry: COMPOSER,
      variant: "codex-chat",
      ready: '[data-composer-look="codex"]',
      act: typeDraft,
      atLeast: 6,
    },
    {
      look: "transcript",
      entry: TRANSCRIPT,
      variant: "activity-tone-secondary",
      ready: ".cv-user__bubble",
      atLeast: 8,
    },
    {
      look: "transcript-links",
      entry: TRANSCRIPT,
      variant: "chips-and-previews",
      ready: ".cv-user__bubble",
      atLeast: 4,
    },
    {
      look: "transcript-permission",
      entry: TRANSCRIPT,
      variant: "permission",
      ready: ".acpmux-permission, .cv-user__bubble",
      atLeast: 4,
    },
    {
      look: "transcript-run-open",
      entry: TRANSCRIPT,
      variant: "collapsed-run-open",
      ready: ".cv-user__bubble",
      atLeast: 6,
    },
  ];
  const matched = new Set<Known>();

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
    await warmGalleryFrame(vite, COMPOSER, { browser, params: { variant: "claude-chat" } });
    await warmGalleryFrame(vite, TRANSCRIPT, { browser, params: { variant: "activity-tone-secondary" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const settle = (page: Page) =>
    page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );

  async function open(page: Page, scene: Scene, theme: Theme) {
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(scene.entry, {
        variant: scene.variant,
        theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
        colorScheme: theme,
      })}`,
    );
    await page.waitForFunction(() => !!document.documentElement.dataset.galleryReady, undefined, {
      timeout: 60_000,
    });
    await page.locator(scene.ready).first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    if (scene.act) await scene.act(page);
    // Hover and focus fades finish before the read: once the pointer has left, every finite
    // animation and transition is run to its end, then two frames paint the settled colors.
    await page.mouse.move(1, 1);
    await settle(page);
    await page.evaluate(() => {
      for (const animation of document.getAnimations())
        if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
    });
    await settle(page);
  }

  for (const scene of SCENES) {
    for (const theme of ["light", "dark"] as const) {
      test(`${scene.look} (${theme}): every line of text and icon meets WCAG AA`, async () => {
        const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
        try {
          await open(page, scene, theme);
          const lines = await readContrast(page);
          expect(lines.length).toBeGreaterThanOrEqual(scene.atLeast);
          const failing = distinctPairs(belowMinimum(lines));
          const lowest = [...lines].sort((a, b) => a.ratio / a.min - b.ratio / b.min).slice(0, 3);
          console.log(
            `look-contrast ${scene.look} ${theme}: ${lines.length} lines, ${failing.length} under the minimum; lowest ${lowest
              .map((line) => `${line.ratio}:1/${line.min} ${line.selector} "${line.text}"`)
              .join(" | ")}`,
          );
          if (out) {
            const name = `${scene.look}-${theme}`;
            writeFileSync(path.join(out, `${name}.json`), JSON.stringify(lines, null, 1));
            writeFileSync(path.join(out, `${name}.png`), await page.screenshot());
          }
          for (const line of failing) {
            const known = knownFor(line);
            if (!known) continue;
            matched.add(known);
            console.log(`look-contrast KNOWN ${scene.look} ${theme}: ${formatPair(line)}`);
          }
          const unexpected = failing
            .filter((line) => !knownFor(line))
            .map((line) => `${scene.look} ${theme}: ${formatPair(line)}`);
          expect(unexpected).toEqual([]);
        } finally {
          await page.close();
        }
      });
    }
  }

  // The detector: light ink on the light bubble, and dark ink on the dark page, are each reported with
  // their element and colors.
  for (const [theme, css, element] of [
    ["light", ".cv-user__typed { color: #d0d0d0 !important; }", "cv-user__typed"],
    ["dark", ".cv-p { color: #3a3a3a !important; }", "cv-p"],
  ] as const) {
    test(`the walker reports ${theme === "light" ? "light on light" : "dark on dark"} text`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
      try {
        await open(
          page,
          SCENES.find((scene) => scene.look === "transcript")!,
          theme,
        );
        await page.addStyleTag({ content: css });
        await settle(page);
        const failing = belowMinimum(await readContrast(page)).filter((line) => line.selector.includes(element));
        expect(failing.length).toBeGreaterThan(0);
        expect(formatPair(failing[0]!)).toMatch(/fg #[0-9a-f]{6} on bg #[0-9a-f]{6} = [\d.]+:1, needs 4\.5:1/);
      } finally {
        await page.close();
      }
    });
  }

  test("every KNOWN pair still fails in some scene (a fixed one leaves the list)", () => {
    expect(
      KNOWN.filter((known) => !matched.has(known)).map((known) => `fixed, remove from KNOWN: ${known.element}`),
    ).toEqual([]);
  });
});
