// cmux-web-test-timeout: 900
// l10n-allow-file: test labels, not shipped UI.
// The composer rim comparison (gallery agent-pane.composer-rim) shows what it says, so a level is
// picked from honest captures (cmux #37594's review: its `before` drew the half glint, and every
// rest/focused pair was the same picture):
// - each level's --acpmux-composer-glint reaches the card (1 for `before`, 0.5 for the quiet levels);
// - a resting stage has no focused field in the card, a focused one matches :has(:focus-visible);
// - the focused card's hairline ring is a different color from the resting one's, in a dark and a
//   light theme.
//
// Real Chromium from Playwright on the real gallery frame; CI fails the file when it cannot launch
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-rim-gallery.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-rim-gallery.test.ts", async () => {
  setDefaultTimeout(840_000);
  const ENTRY = "agent-pane.composer-rim";
  const LEVELS: Record<string, number> = { before: 1, "quiet-16-22": 0.5, "quiet-14-20": 0.5, "quiet-18-22": 0.5 };
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser, params: { variant: "before-rest" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type State = { glint: string; ring: string; focusVisible: boolean; focusWithin: boolean; marked?: string };

  async function open(variant: string, colorScheme: "dark" | "light"): Promise<{ page: Page; state: State }> {
    const page = await browser!.newPage({ viewport: { width: 760, height: 360 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, colorScheme, width: 760 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    const state = await page.evaluate(() => {
      const box = document.querySelector<HTMLElement>(".acpmux-composer > .acpmux-composer-box")!;
      const style = getComputedStyle(box);
      return {
        glint: style.getPropertyValue("--acpmux-composer-glint").trim(),
        // The ring: the card's --acpmux-card-ring, the inset hairline that focus lifts.
        ring: style.getPropertyValue("--acpmux-card-ring").trim(),
        focusVisible: box.matches(":has(:focus-visible)"),
        focusWithin: box.matches(":focus-within"),
        marked: document.documentElement.dataset.composerRimState,
      };
    });
    return { page, state };
  }

  for (const colorScheme of ["dark", "light"] as const)
    for (const [level, glint] of Object.entries(LEVELS))
      test(`${colorScheme} ${level}: the glint reaches the card, and rest and focused differ`, async () => {
        const rest = await open(`${level}-rest`, colorScheme);
        const focused = await open(`${level}-focused`, colorScheme);
        await rest.page.close();
        await focused.page.close();
        expect(Number(rest.state.glint), `${level} glint at rest`).toBe(glint);
        expect(Number(focused.state.glint), `${level} glint focused`).toBe(glint);
        expect(rest.state.focusWithin, "a resting card holds no focus").toBe(false);
        expect(rest.state.focusVisible).toBe(false);
        expect(focused.state.focusVisible, "a focused card matches :has(:focus-visible)").toBe(true);
        expect(focused.state.ring, "the focused ring differs from the resting one").not.toBe(rest.state.ring);
        // The stage reached its state before the capture (composerRim.gallery.ts marks it).
        expect([rest.state.marked, focused.state.marked]).toEqual(["rest", "focused"]);
      });
});
