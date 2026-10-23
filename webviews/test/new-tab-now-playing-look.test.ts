// cmux-web-test-timeout: 300
// The New Tab page's Now Playing card in Chromium (Leo 2026-10-19: "it should be able to be right
// clickable and it should be styled better and disableable"). A long title and artist each stay
// on one line and end in an ellipsis without widening the card or moving the controls; the card is
// one soft surface with a hairline edge and concentric rounded artwork; Previous and Next fill a
// soft round under the pointer while Play or Pause is the one filled control; the right-click menu
// opens at the pointer with its items; and once the host clears the track (the setting turned off)
// the page lays out exactly as the page that never had a track, so no space is kept.
//
// It renders the real New Tab screen on the gallery stage. CI fails the file when it cannot launch
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-now-playing-look.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-now-playing-look.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("new tab now playing look", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.new-tab", { variant, frame: "component", width: 760, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Resolves once nothing on the page is easing: no transition or animation left to run (a
   *  looping one, the level bars, never ends). */
  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  const open = async (variant: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 720 } });
    for (;;) {
      await page.goto(stageURL(variant));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        // The first load can run Vite's dependency optimizer and reload mid-compile.
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.evaluate(() => document.fonts.ready);
    if (variant !== "now-playing-off") await page.waitForSelector(".nt-player, .nt-player-note");
    await page.mouse.move(1, 1);
    await eased(page);
    return page;
  };
  const box = (page: Page, selector: string) =>
    page
      .locator(selector)
      .first()
      .evaluate((element) => {
        const rect = element.getBoundingClientRect();
        return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
      });
  const filled = (page: Page, selector: string) =>
    page
      .locator(selector)
      .first()
      .evaluate((element) => {
        const color = getComputedStyle(element).backgroundColor;
        return !(color === "transparent" || /rgba\(.*,\s*0\)$/.test(color));
      });

  test("a long title and artist end in an ellipsis; the card and its controls keep their place", async () => {
    const short = await open("now-playing-paused");
    const long = await open("now-playing-long-title");
    for (const selector of [".nt-player-title", ".nt-player-artist"]) {
      const text = await long.locator(selector).evaluate((element) => {
        const style = getComputedStyle(element);
        return {
          overflows: element.scrollWidth > element.clientWidth,
          ellipsis: style.textOverflow,
          nowrap: style.whiteSpace,
          lines: Math.round(element.getBoundingClientRect().height / parseFloat(style.lineHeight)),
        };
      });
      expect(text, selector).toEqual({ overflows: true, ellipsis: "ellipsis", nowrap: "nowrap", lines: 1 });
    }
    const [card, longCard] = [await box(short, ".nt-player"), await box(long, ".nt-player")];
    expect(longCard.width, "the long title widened the card").toBe(card.width);
    expect(longCard.width).toBeLessThanOrEqual(440);
    expect(longCard.height, "the long title grew the card").toBe(card.height);
    const [play, longPlay] = [await box(short, ".nt-player-play"), await box(long, ".nt-player-play")];
    expect(longPlay.left, "the long title moved the controls").toBe(play.left);
    const [bars, longBars] = [await box(short, ".nt-player-levels"), await box(long, ".nt-player-levels")];
    expect(longBars.left + longBars.width, "the long title pushed the level bars out").toBe(bars.left + bars.width);
    await short.close();
    await long.close();
  });

  test("one soft card with concentric artwork; Play or Pause is the one filled control; hover fills Previous", async () => {
    const page = await open("now-playing-paused");
    const card = await page.locator(".nt-player").evaluate((element) => {
      const style = getComputedStyle(element);
      return {
        radius: parseFloat(style.borderTopLeftRadius),
        padding: parseFloat(style.paddingTop),
        shadow: style.boxShadow,
      };
    });
    expect(card.shadow, "the card has no hairline edge").toContain("inset");
    const art = await page
      .locator(".nt-player-art")
      .evaluate((element) => parseFloat(getComputedStyle(element).borderTopLeftRadius));
    expect(art, "the artwork is not concentric with the card").toBe(card.radius - card.padding);
    expect(await filled(page, ".nt-player"), "the card has no fill").toBe(true);
    expect(await filled(page, ".nt-player-play"), "Play is not filled").toBe(true);
    expect(await filled(page, '.nt-player [data-command="previous"]'), "Previous is filled at rest").toBe(false);
    const fine = await page.evaluate(() => matchMedia("(hover: hover) and (pointer: fine)").matches);
    if (fine) {
      const previous = await box(page, '.nt-player [data-command="previous"]');
      await page.mouse.move(previous.left + previous.width / 2, previous.top + previous.height / 2);
      await page.waitForFunction(() =>
        document.querySelector('.nt-player [data-command="previous"]')?.matches(":hover"),
      );
      await eased(page);
      expect(await filled(page, '.nt-player [data-command="previous"]'), "hover draws no round").toBe(true);
    }
    // No artwork: the music note sits in the same rounded slot.
    const bare = await open("now-playing-no-artwork");
    expect(await bare.locator(".nt-player-art-empty svg").count()).toBe(1);
    expect((await box(bare, ".nt-player-art")).width).toBe((await box(page, ".nt-player-art")).width);
    await bare.close();
    await page.close();
  });

  test("the right-click menu opens at the pointer with the card's items", async () => {
    const page = await open("now-playing-menu");
    const items = await page
      .locator('.ui-context-menu [role="menuitem"]')
      .evaluateAll((nodes) => nodes.map((node) => [node.textContent, (node as HTMLButtonElement).disabled]));
    expect(items).toEqual([
      ["Pause", false],
      ["Next Track", true],
      ["Previous Track", false],
      ["Open in Spotify", false],
      ["Hide Now Playing", false],
      ["Now Playing Settings…", false],
    ]);
    const menu = await box(page, ".ui-context-menu");
    expect(menu.width, "the menu is not drawn").toBeGreaterThan(0);
    await page.close();
  });

  test("once the host clears the track the page lays out as if it never had the card", async () => {
    // Where each of the screen's blocks sits, and how tall the screen is.
    const layout = (page: Page) =>
      page.evaluate(() => {
        const screen = document.querySelector<HTMLElement>(".nt-screen")!;
        return {
          height: Math.round(screen.scrollHeight),
          blocks: [...screen.querySelectorAll<HTMLElement>(":scope > *")]
            .filter((element) => element.getBoundingClientRect().height > 0)
            .map((element) => `${element.className.split(" ")[0]}@${Math.round(element.getBoundingClientRect().top)}`),
        };
      });
    const never = await open("now-playing-off");
    const plain = await layout(never);
    await never.close();
    const page = await open("now-playing-paused");
    expect(await layout(page), "the card moved nothing").not.toEqual(plain);
    await page.evaluate(async () => {
      document.defaultView?.cmuxAcpmuxBridge?.applyNowPlaying?.(null);
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    expect(await page.locator(".nt-player").count()).toBe(0);
    expect(await layout(page), "space was kept for the hidden card").toEqual(plain);
    await page.close();
  });
});
