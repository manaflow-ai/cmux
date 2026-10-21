// Agent-pane gallery entries that had stopped showing the product (gallery sweep, 2026-10-20).
// Each must reach its state with real content: no play error, no stage that is blank or alone.
//
// Before, the product had moved on and the entries had not:
// - controls renamed or moved: the sidebar's search field is "Search chats" (#19895), the start
//   folder's home row reads "~" (#22724), Revoke lives in the composer's access menu (#20303), and
//   the composer-context strip shows only before a chat's first send (#20869);
// - plays that raced the stage: the header's pull-request chip, the dictation button's menu;
// - stages that drew one part alone, so a play that removes it left nothing: the harness notice
//   after Not Now, the file search after Escape, a new chat with no home lists, and a local reply
//   image whose host answer the fixture never gave.
//
// Real Chromium from Playwright, on the gallery's dev server; CI fails the file when it cannot
// launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Case = {
  entry: string;
  variant: string;
  /** The play's report must have no failure (a play with no measured steps checks only `error`). */
  play?: "steps" | "error";
  /** What the stage must show when it is ready. */
  shows?: (page: Page) => Promise<boolean>;
};

const has = (selector: string) => async (page: Page) => (await page.locator(selector).count()) > 0;

const CASES: Case[] = [
  { entry: "session-sidebar", variant: "search-filtered", play: "steps" },
  { entry: "session-sidebar", variant: "search-clears", play: "steps" },
  { entry: "start-folder", variant: "home-question", play: "steps" },
  { entry: "start-folder", variant: "root-refused", play: "steps" },
  { entry: "permission-panel", variant: "allowance", play: "error" },
  { entry: "bottom-stack", variant: "pr-queue", play: "steps" },
  { entry: "header-tools", variant: "pull-request-status", play: "steps" },
  { entry: "header-tools", variant: "pull-request-merge", play: "steps" },
  { entry: "dictation", variant: "hide", play: "steps" },
  { entry: "harness-health-notice", variant: "dismissed", play: "error", shows: has(".acpmux-composer") },
  { entry: "harness-health-notice", variant: "sudo-update", shows: has(".acpmux-composer") },
  { entry: "file-search", variant: "escape", play: "steps", shows: has(".acpmux-composer") },
  {
    entry: "home-lists",
    variant: "empty",
    shows: async (page) => (await page.getByText("What should we build in atlas-web?").count()) > 0,
  },
  {
    entry: "reply-image",
    variant: "local",
    shows: (page) =>
      page.evaluate(() => [...document.images].some((image) => image.complete && image.naturalWidth > 0)),
  },
];

await requireBrowserLane("gallery-agent-pane-entries.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("gallery-agent-pane-entries: skipping (run `bunx playwright install chromium`)");
    describe.skip("agent-pane gallery entries", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = ({ entry, variant }: Case) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.${entry}&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const item of CASES)
    test(`agent-pane.${item.entry}#${item.variant} shows the product`, async () => {
      const page = await browser!.newPage({ viewport: { width: 1000, height: 800 } });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      for (;;) {
        try {
          await page.goto(url(item));
          // The first page waits on a cold Vite compiling the gallery, past 30 s on a busy runner.
          await page.waitForFunction(
            (play) => {
              const root = document.documentElement.dataset;
              return root.galleryReady === "error" || (root.galleryReady === "1" && (!play || Boolean(root.galleryPlay)));
            },
            Boolean(item.play),
            { timeout: 90_000 },
          );
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
      const report = await page.evaluate(() =>
        JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport ?? {}),
      );
      const shows = item.shows ? await item.shows(page) : true;
      await page.close();
      expect(errors).toEqual([]);
      expect(ready).toBe("1");
      if (item.play === "steps") expect(playFailures(report)).toEqual([]);
      if (item.play === "error") expect((JSON.parse(report) as { error?: string }).error).toBeUndefined();
      expect(shows, report).toBe(true);
    });
});
