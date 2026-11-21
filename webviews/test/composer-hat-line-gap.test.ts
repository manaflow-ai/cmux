// cmux-web-test-timeout: 300
// The card's top line stops at the tucked composer hat's pill (subagents/TrayPullTab.tsx) and never
// runs through its glass (Leo, 2026-11-09: "theres a line behind the hat toggle. i dont mean the glass
// rim i mean there's a line in the midle"). It renders the gallery stage `agent-pane.composer-hat`
// in Chromium, in a dark and a light theme, and compares the pixels of each state with the same page
// once the card draws no ring and no rim at all: inside the pill (its rim left out) the two must
// match, so nothing of the card's line paints behind the glass; just outside the pill they must
// differ, so the line still runs up to the pill's rim. `line-before` (the old pairing, the line
// under the pill) must fail the inside check, so the check sees the line it guards against. While
// the pill grows into its count, the gap in the line follows its edges every frame. The part the pill
// sits on need not span the tab's column: a narrow pane's card and queue reach 8 px past it, and
// Codex's location strip sits 22 px inside it, so with the handle at the left or the right the gap
// must still land under the pill there; and a queue's or strip's gap moves with the pill's width.
// Beside the pill, over the card's line, the hat draws nothing of its own (Leo, 2026-11-11: "did this
// line behind the count box get removed yet?"): the pill's old 8px stubs ran 2px over the card's line
// and poked out on both sides as a second line behind the count. `bridge-before` (those stubs drawn
// again, gallery only) must fail that check, so the check sees the stubs it guards against.
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-hat-line-gap.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-hat-line-gap.test.ts", async () => {
  const ENTRY = "agent-pane.composer-hat";
  const SCALE = 2;
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer hat line gap", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string, theme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width: 640, theme })}`;

  beforeAll(async () => {
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
    await browser?.close();
    await vite?.close();
  });

  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  const open = async (variant: string, theme: string, hat = true): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 640, height: 260 }, deviceScaleFactor: SCALE });
    for (;;) {
      await page.goto(stageURL(variant, theme));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(1, 1);
    if (hat) await page.waitForSelector(".acpmux-tray-pull__hat");
    await eased(page);
    return page;
  };
  type Box = { left: number; right: number; top: number; bottom: number };
  const rects = (page: Page) =>
    page.evaluate(() => {
      const box = (el: Element) => {
        const r = el.getBoundingClientRect();
        return { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
      };
      return {
        pill: box(document.querySelector(".acpmux-tray-pull__hat")!),
        // The part the pill sits on: a queue or strip over the card, else the card.
        card: box(document.querySelector("[data-stage-top]") ?? document.querySelector("[data-stage-composer]")!),
      };
    });
  /** The band around the card's top edge, as device pixels. */
  const shot = async (page: Page, band: Box) => {
    const png = PNG.sync.read(
      await page.screenshot({
        clip: { x: band.left, y: band.top, width: band.right - band.left, height: band.bottom - band.top },
      }),
    );
    return png;
  };
  /** The largest channel difference between two shots in the given columns (CSS px from the band's left). */
  const diff = (a: PNG, b: PNG, from: number, to: number) => {
    let most = 0;
    for (let y = 0; y < a.height; y += 1)
      for (let x = Math.max(0, Math.round(from * SCALE)); x < Math.min(a.width, Math.round(to * SCALE)); x += 1)
        for (let c = 0; c < 3; c += 1) {
          const i = (y * a.width + x) * 4 + c;
          most = Math.max(most, Math.abs(a.data[i]! - b.data[i]!));
        }
    return most;
  };
  /** Inside the pill (its rim and 2px of slack left out), and 2-6px out from each side of it. */
  const measureOn = async (page: Page) => {
    const { pill, card } = await rects(page);
    // Rows from just over the card's top edge to 4px under it: the line and the lit rim under it.
    const band = { left: pill.left - 8, right: pill.right + 8, top: card.top - 2, bottom: card.top + 4 };
    const drawn = await shot(page, band);
    const bare = await page.addStyleTag({
      content:
        ".acpmux-composer-box { --acpmux-card-ring: 0 0 transparent !important; --acpmux-composer-rim: 0 0 transparent !important; }" +
        " .acpmux-composer > :is(.acpmux-composer-queue, .acpmux-composer-strip) { box-shadow: none !important; }",
    });
    const plain = await shot(page, band);
    await bare.evaluate((node) => (node as HTMLStyleElement).remove());
    const width = band.right - band.left;
    // Beside the pill, 1-12px out from each side, from its top down to just over the card's line: the
    // same page with the pill not drawn must match, so the pill hangs no line out past its rim.
    const side = { left: pill.left - 12, right: pill.right + 12, top: pill.top, bottom: card.top - 1 };
    const withPill = await shot(page, side);
    const hidden = await page.addStyleTag({ content: ".acpmux-tray-pull { visibility: hidden !important; }" });
    const withoutPill = await shot(page, side);
    await hidden.evaluate((node) => (node as HTMLStyleElement).remove());
    // The shot's own width: a clip at a fractional edge comes back a device pixel narrower.
    const sideWidth = withPill.width / SCALE;
    return {
      inside: diff(drawn, plain, 8 + 2, width - 8 - 2),
      left: diff(drawn, plain, 8 - 6, 8 - 2),
      right: diff(drawn, plain, width - 8 + 2, width - 8 + 6),
      besideLeft: diff(withPill, withoutPill, 0, 12 - 1),
      besideRight: diff(withPill, withoutPill, sideWidth - 12 + 1, sideWidth),
    };
  };
  const measure = async (variant: string, theme: string) => {
    const page = await open(variant, theme);
    const seen = await measureOn(page);
    await page.close();
    return seen;
  };
  const clean = (seen: Awaited<ReturnType<typeof measure>>, label: string) => {
    expect(seen.inside, `${label}: the card's line paints nothing inside the pill`).toBeLessThanOrEqual(3);
    expect(seen.left, `${label}: the line still runs up to the pill's left rim`).toBeGreaterThan(6);
    expect(seen.right, `${label}: the line still runs up to the pill's right rim`).toBeGreaterThan(6);
    expect(seen.besideLeft, `${label}: no line of the pill's own pokes out on its left`).toBeLessThanOrEqual(3);
    expect(seen.besideRight, `${label}: no line of the pill's own pokes out on its right`).toBeLessThanOrEqual(3);
  };

  const THEMES = ["Catppuccin Mocha", "Apple System Colors Light"];
  for (const theme of THEMES) {
    for (const variant of [
      "idle",
      "line-seven",
      "line-many",
      "waiting",
      "line-left",
      "line-right",
      // The part under the pill is offset from the tab's column, or is a queue or strip.
      "line-narrow",
      "line-narrow-left",
      "line-narrow-right",
      "line-strip",
      "line-strip-left",
      "line-strip-right",
      "line-strip-narrow-left",
      "line-queue",
      "line-queue-many",
      "line-queue-narrow-left",
      // The pill's place on the line (gallery candidates): neither hangs a line out past the pill.
      // (bridge-perched sits on the line, so the line runs under its foot: not this check's shape.)
      "bridge-none",
      "bridge-seated",
    ])
      test(`${theme}, ${variant}: no line behind the pill's glass, the line runs up to its rim`, async () => {
        clean(await measure(variant, theme), `${theme}, ${variant}`);
      });

    test(`${theme}, line-before: the check sees the line through the old pill`, async () => {
      const seen = await measure("line-before", theme);
      expect(seen.inside, "the old pairing draws the card's line through the pill").toBeGreaterThan(6);
    });

    test(`${theme}, bridge-before: the check sees the old stubs beside the pill`, async () => {
      const seen = await measure("bridge-before", theme);
      expect(seen.besideLeft, "the old stub pokes out on the pill's left").toBeGreaterThan(6);
      expect(seen.besideRight, "the old stub pokes out on the pill's right").toBeGreaterThan(6);
    });
  }

  // Halfway through the pill's growth into its count (and back), held there: the gap is the pill's
  // width in that frame too, so no line shows inside it and none is missing beside it.
  for (const [from, to] of [
    ["idle", "ten"],
    ["two-digits", "idle"],
    // A queue's or Codex strip's top line: its gap moves with the pill too, never a jump to the end.
    ["line-queue-many", "idle"],
    ["line-queue", "ten"],
    ["line-strip", "idle"],
    ["line-strip-left", "ten"],
  ] as const)
    test(`mid-transition, ${from} to ${to}: the gap follows the pill's edges`, async () => {
      const page = await open(from, "Catppuccin Mocha");
      await page.evaluate(
        (button) =>
          new Promise<void>((resolve) => {
            document.querySelector<HTMLElement>(`[data-stage="${button}"]`)!.click();
            requestAnimationFrame(() => {
              for (const animation of document.getAnimations()) {
                const duration = Number(animation.effect?.getTiming().duration ?? 0);
                if (animation.playState !== "running" || !(duration > 0)) continue;
                animation.pause();
                animation.currentTime = duration * 0.4;
              }
              resolve();
            });
          }),
        to === "ten" ? "ten" : "idle",
      );
      const moving = await page.evaluate(
        () => document.querySelector(".acpmux-tray-pull__slot")!.getAnimations().length > 0,
      );
      expect(moving, "the pill is mid-transition").toBe(true);
      const seen = await measureOn(page);
      await page.close();
      clean(seen, `${from} to ${to}`);
    });

  // Tucking the hat while work runs mounts the pill already at its count's width: the gap is that
  // width from the first frame, never growing into it while the line shows through the count.
  test("tucked while twelve run: the gap is the pill's width from its first frame", async () => {
    const page = await open("line-tuck", "Catppuccin Mocha", false);
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          document.querySelector<HTMLElement>('[data-stage="tuck"]')!.click();
          requestAnimationFrame(() => {
            for (const animation of document.getAnimations()) {
              const duration = Number(animation.effect?.getTiming().duration ?? 0);
              if (animation.playState !== "running" || !(duration > 0)) continue;
              animation.pause();
              animation.currentTime = duration * 0.4;
            }
            resolve();
          });
        }),
    );
    await page.waitForSelector(".acpmux-tray-pull__count");
    const seen = await measureOn(page);
    await page.close();
    clean(seen, "tucked while twelve run");
  });
});
