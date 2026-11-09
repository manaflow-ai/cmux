// RUNNING-WAVE in the gallery (Leo 2026-10-21, ask-05b0074927) once swept Session Info's running
// Subagents lines. The lean Session Info draws them still (Lucas, 2026-11-05), so its `subagents-wave`
// state now shows no wave: no line is in one, no wave loop runs, and the frame does not move between
// two reads. running-wave-loops.test.ts covers the running tray's live loops and what stops them.
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

  // Lucas, 2026-11-05 (Session Info lab): Session Info's Subagents draw lean lines, each its mark, name
  // and time, with no wave and no spinner; the ended ones fold into one plain row. The gallery's
  // `subagents-wave` state keeps its running lines, so it shows that nothing sweeps there now.
  test("subagents-wave draws its running lines still: no wave loop, and the frame stays put", async () => {
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
    expect(root.ready).toBe("1");

    const first = await icons(page);
    const running = first.filter((icon) => icon.state === "running");
    // Several running lines lead the list, none of them in a wave, all at one strength.
    expect(running.length).toBeGreaterThanOrEqual(4);
    expect(first.some((icon) => icon.wave)).toBe(false);
    expect(new Set(running.map((icon) => icon.opacity)).size).toBe(1);
    expect(await loops(page)).toEqual([]);

    // A full former wave period later (1.6 s on the page's own timeline): nothing moved.
    const at = await page.evaluate(() => Number(document.timeline.currentTime));
    await page.waitForFunction((from) => Number(document.timeline.currentTime) > from + 1_700, at);
    expect(await icons(page)).toEqual(first);
    expect(await loops(page)).toEqual([]);
    await page.close();
  });
});
