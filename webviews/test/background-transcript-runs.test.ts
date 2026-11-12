// l10n-allow-file: the gallery fixture supplies the step titles and counts these checks read.
// cmux-web-test-timeout: 300
//
// A helper's transcript in the Background tasks panel folds the work between its replies, as Claude
// Code's drill-in does (Leo, 2026-11-09: "this claude background tasks thing and being able to click
// into subagents'/helpers' stuff is really good"): a stretch of two or more calls is one quiet line,
// "Ran 11 commands, 2 failed", that opens in place to its steps; a lone call keeps its own line. Before,
// every call and every thought drew a line of its own, so the helper's prose drowned in "Thought
// process" lines. Gallery `agent-pane.background-tasks` `transcript` (the attribution helper: eleven
// steps, each a thought and a call, two failed; a reply; one call still running).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("background-transcript-runs.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.background-tasks";
  const RUNS = "agent-pane.background-tasks-runs";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY, RUNS], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry = ENTRY, variant = "transcript"): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 1280, height: 800 } });
    const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
    await page.goto(base + galleryFrame(entry, { variant }));
    await page.waitForFunction(
      () => {
        const root = document.documentElement.dataset;
        return root.galleryReady === "error" || (root.galleryReady === "1" && Boolean(root.galleryPlay));
      },
      undefined,
      { timeout: 90_000 },
    );
    expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
    return page;
  };

  /** What the transcript shows: its lines' text, top to bottom, folded runs as one line each. */
  const lines = (page: Page) =>
    page.$$eval(".acpmux-bg__transcript .acpmux-bg__line--fold", (nodes) =>
      nodes.filter((node) => node.getClientRects().length > 0).map((node) => node.textContent?.trim() ?? ""),
    );

  test("the stretch of work between replies is one line that opens to its steps", async () => {
    const page = await open();
    try {
      const shown = await lines(page);
      console.log("LINES", JSON.stringify(shown));
      // The eleven steps before the reply: one line naming them, their failures counted.
      const runs = shown.filter((text) => text.startsWith("Ran 11 commands"));
      expect(runs).toHaveLength(1);
      expect(runs[0]).toContain("2 failed");
      // Their thoughts fold with them: none draws a line while the run is folded.
      expect(shown.filter((text) => text === "Thought process")).toHaveLength(0);
      // The lone call after the reply keeps its own line.
      expect(shown).toContain("Start the Codex review detached");
      // The reply reads between them, never folded.
      expect(await page.locator(".acpmux-bg__transcript .acpmux-bg__reply").count()).toBe(1);

      // Opened in place: every step and its thought, on the run's own fold.
      await page.locator(".acpmux-bg__run .acpmux-bg__line--fold").first().click();
      await page.waitForFunction(
        () => document.querySelectorAll(".acpmux-bg__run-steps .acpmux-bg__tool").length === 11,
      );
      const opened = await lines(page);
      expect(opened.filter((text) => text === "Thought process")).toHaveLength(11);
      expect(opened).toContain("Read an xcstrings entry and i18n loader");
      expect(await page.locator('.acpmux-bg__run .acpmux-bg__line--fold[aria-expanded="true"]').count()).toBe(1);

      // A second click folds it again.
      await page.locator(".acpmux-bg__run .acpmux-bg__line--fold").first().click();
      await page.waitForFunction(() => !document.querySelector(".acpmux-bg__run-steps"));
    } finally {
      await page.close();
    }
  });
  // More calls in one run than the transcript mounts at once (MOUNTED rows): the window pages by what
  // it draws, so the one folded line never leaves both paging sentinels in view, swapping the mounted
  // rows back and forth with nobody scrolling (#39368's review).
  test("a run longer than the mounted window is one line that holds still", async () => {
    const page = await open(RUNS, "long-run");
    try {
      const frames = (n: number) =>
        page.evaluate(
          (count) =>
            new Promise<void>((resolve) => {
              let left = count;
              // raf-read: it only lets frames pass for the sentinels' observers to fire; the state is read after.
              const step = () => (--left <= 0 ? resolve() : requestAnimationFrame(step));
              requestAnimationFrame(step);
            }),
          n,
        );
      const state = () =>
        page.evaluate(() => ({
          lines: [...document.querySelectorAll(".acpmux-bg__transcript .acpmux-bg__line--fold")].map(
            (node) => node.textContent?.trim() ?? "",
          ),
          sentinels: document.querySelectorAll(".acpmux-bg__transcript .acpmux-bg__sentinel").length,
          run: document.querySelector(".acpmux-bg__run")?.getAttribute("data-run-id") ?? null,
        }));
      const before = await state();
      console.log("LONG", JSON.stringify(before));
      expect(before.lines).toEqual(["Ran 240 commands"]);
      expect(before.sentinels).toBe(0);
      await frames(30);
      expect(await state()).toEqual(before);
    } finally {
      await page.close();
    }
  });
});
