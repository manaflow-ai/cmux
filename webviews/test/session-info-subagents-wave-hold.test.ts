// RUNNING-WAVE in the gallery (Leo 2026-10-21, ask-05b0074927: "THESE GLIMMER AT DIFFERENT INTERVALS
// ... it would look cool if they went in a wave, like how thinking glimmers in ChatGPT"). Screenshots
// come from the gallery, so Session Info's `subagents-wave` state holds the wave mid-sweep: the
// running lines' icons sit at different points of one shimmer by their place in the list (dim,
// brighter, the crest, brighter, dim, top to bottom), the one row of the finished and the failed one
// at full strength, and the frame does not move between two reads. running-wave-loops.test.ts covers the live loops and what
// stops them.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-subagents-wave-hold.test.ts", async () => {
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.chat-inspector";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Each line's icon in Subagents, in order: its state, whether it is in the wave, its opacity now. */
  const icons = (page: Page) =>
    page.evaluate(() =>
      [
        ...document.querySelectorAll(
          ".acpmux-session-info-subagents .acpmux-lineage__icon, .acpmux-session-info-subagents__avatars .cv-subagent-avatar",
        ),
      ].map((icon) => ({
        state: icon.getAttribute("data-state"),
        wave: icon.classList.contains("acpmux-wave-item"),
        opacity: Number(getComputedStyle(icon).opacity),
      })),
    );

  /** The wave loops: whether each is paused, and where it is held. */
  const loops = (page: Page) =>
    page.evaluate(() =>
      document
        .getAnimations()
        .filter((animation) => (animation as CSSAnimation).animationName === "cmux-wave")
        .map((animation) => ({ state: animation.playState, at: Number(animation.currentTime) })),
    );

  test("subagents-wave holds the running lines mid-sweep, by index, and the frame stays put", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 420, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "subagents-wave" })}`);
    // The first page waits on a cold Vite compiling the gallery, past 30 s on a busy runner.
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
      timeout: 90_000,
    });
    const root = await page.evaluate(() => {
      const { galleryReady, galleryPlay } = document.documentElement.dataset;
      return { ready: galleryReady, play: galleryPlay };
    });
    expect(root).toEqual({ ready: "1", play: "none" });

    const first = await icons(page);
    const running = first.filter((icon) => icon.wave);
    const still = first.filter((icon) => !icon.wave);
    // Several running lines lead the list; the completed summary's failed and done avatars
    // follow, outside the wave.
    expect(running.length).toBeGreaterThanOrEqual(4);
    expect(running.every((icon) => icon.state === "running")).toBe(true);
    expect(first.slice(0, running.length).every((icon) => icon.wave)).toBe(true);
    expect(still.map((icon) => icon.state)).toEqual(["failed", "completed"]);
    expect(still.map((icon) => icon.opacity)).toEqual([1, 1]);

    // Every wave loop is paused at the one shared point, so only its index sets its phase.
    const held = await loops(page);
    expect(held.length).toBe(running.length);
    expect(held.every((loop) => loop.state === "paused")).toBe(true);
    expect(new Set(held.map((loop) => loop.at)).size).toBe(1);

    // Mid-sweep: the crest sits on a line inside the list; the opacities rise to it and fall after
    // it in index order, each one visibly different from every other.
    const opacity = running.map((icon) => icon.opacity);
    const crest = opacity.indexOf(Math.max(...opacity));
    expect(crest).toBeGreaterThan(0);
    expect(crest).toBeLessThan(opacity.length - 1);
    for (let index = 1; index <= crest; index++) expect(opacity[index]! - opacity[index - 1]!).toBeGreaterThan(0.02);
    for (let index = crest + 1; index < opacity.length; index++)
      expect(opacity[index - 1]! - opacity[index]!).toBeGreaterThan(0.02);
    for (const [index, value] of opacity.entries())
      for (const other of opacity.slice(index + 1)) expect(Math.abs(value - other)).toBeGreaterThan(0.02);
    expect(Math.max(...opacity)).toBeGreaterThan(0.95);
    expect(Math.min(...opacity)).toBeLessThan(0.75);
    expect(Math.min(...opacity)).toBeGreaterThanOrEqual(0.55);

    // The same frame a full wave period later (1.6 s on the page's own timeline): nothing moved.
    const at = await page.evaluate(() => Number(document.timeline.currentTime));
    await page.waitForFunction((from) => Number(document.timeline.currentTime) > from + 1_700, at);
    expect(await icons(page)).toEqual(first);
    expect(await loops(page)).toEqual(held);
    await page.close();
  });
});
