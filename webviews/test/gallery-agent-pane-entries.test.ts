// Agent-pane gallery entries that had stopped showing the product (gallery sweep, 2026-10-20).
// Each must reach its state with real content: no play error, no stage that is blank or alone.
//
// Before, the product had moved on and the entries had not:
// - controls renamed or moved: the sidebar's search field is "Search chats" (#19895), the start
//   folder's home row reads "~" (#22724), Revoke lives in the composer's access menu (#20303), and
//   the composer-context strip shows only before a chat's first send (#20869);
// - plays that raced the stage: the header's pull-request chip, the dictation button's menu;
// - stages that drew one part alone, so a play that removes it left nothing: the harness notice
//   after Not Now, the file search after Escape, and a new chat with no home lists. Each now
//   draws in the pane's frame; `shows` checks the frame is still there (the stage is not blank)
//   and that the component itself drew what the variant is for.
//
// Real Chromium from Playwright, on the gallery's dev server; CI fails the file when it cannot
// launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Case = {
  entry: string;
  variant: string;
  /** The play's report must have no failure (a play with no measured steps checks only `error`). */
  play?: "steps" | "error";
  /** What the stage must show when it is ready. */
  shows?: (page: Page) => Promise<boolean>;
};

await requireBrowserLane("gallery-agent-pane-entries.test.ts", async () => {
  const count = (page: Page, selector: string) => page.locator(selector).count();
  const has = (selector: string) => async (page: Page) => (await count(page, selector)) > 0;
  /** The pane's composer is in view and no harness notice is drawn. */
  const composerWithoutNotice = async (page: Page) =>
    (await count(page, ".acpmux-composer")) > 0 && (await count(page, "[data-harness-notice]")) === 0;

  const CASES: Case[] = [
    { entry: "start-folder", variant: "home-question", play: "steps" },
    { entry: "start-folder", variant: "root-refused", play: "steps" },
    { entry: "permission-panel", variant: "allowance", play: "error" },
    { entry: "bottom-stack", variant: "pr-queue", play: "steps" },
    { entry: "header-tools", variant: "pull-request-status", play: "steps" },
    { entry: "header-tools", variant: "pull-request-merge", play: "steps" },
    { entry: "dictation", variant: "hide", play: "steps" },
    { entry: "harness-health-notice", variant: "dismissed", play: "steps", shows: composerWithoutNotice },
    {
      entry: "harness-health-notice",
      variant: "sudo-update",
      // An update that needs sudo is neither a line nor the model chip's offer (Settings owns it).
      shows: async (page) => (await composerWithoutNotice(page)) && (await count(page, "[data-harness-offer]")) === 0,
    },
    // Restart Chat and the busy spinner come and go without moving Not Now or the words (layout
    // shift 0); the failed update's Try Again keeps that order too.
    { entry: "harness-health-notice", variant: "restart-after-turn", play: "steps" },
    { entry: "harness-health-notice", variant: "update-failed", play: "steps" },
    { entry: "file-search", variant: "escape", play: "steps", shows: has(".acpmux-composer") },
    {
      entry: "home-lists",
      variant: "empty",
      // The new chat's hero and composer, and no list rows in the home area.
      shows: async (page) =>
        (await count(page, ".acpmux-empty-title")) > 0 &&
        (await count(page, ".acpmux-composer")) > 0 &&
        (await count(page, ".acpmux-home-area > *")) === 0,
    },
    // Nothing is seeded: the image waits on the host's link.inspect answer, as in the app.
    {
      entry: "reply-image",
      variant: "local",
      shows: (page) =>
        page.evaluate(() => [...document.images].some((image) => image.complete && image.naturalWidth > 0)),
    },
    // The summary card is a popover in a pane too narrow for its inline column (#21564): the
    // Summary button opens it, and it lists the subagents.
    ...["summary", "card-kinds", "card-waiting", "card-collapsed", "card-closed", "card-outside-click"].map(
      (variant): Case => ({ entry: "subagents", variant, play: "steps" }),
    ),
    {
      entry: "subagents",
      variant: "card-open-pane",
      play: "steps",
      shows: has(".acpmux-summary-card .acpmux-summary-agents"),
    },
    { entry: "subagents", variant: "card-open-child", play: "steps", shows: has(".cv-subagent-of") },
    // The summary's Outputs row offers the chat's gallery; it opens as a dialog, filters by kind,
    // and an image tile opens the image viewer.
    { entry: "chat-gallery", variant: "outputs", play: "steps", shows: has(".acpmux-summary-gallery") },
    { entry: "chat-gallery", variant: "open", play: "steps", shows: has(".acpmux-chat-gallery-tile") },
    {
      entry: "chat-gallery",
      variant: "renders",
      play: "steps",
      shows: async (page) =>
        (await count(page, ".acpmux-chat-gallery-tile.is-render")) === 2 &&
        (await count(page, ".acpmux-chat-gallery-tile:not(.is-render)")) === 0,
    },
    {
      entry: "chat-gallery",
      variant: "image",
      play: "steps",
      shows: async (page) => (await page.getByRole("dialog", { name: "Weekly builds" }).count()) > 0,
    },
  ];

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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(`agent-pane.${entry}`, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [...new Set(CASES.map(({ entry }) => `agent-pane.${entry}`))], { browser });
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
              return (
                root.galleryReady === "error" || (root.galleryReady === "1" && (!play || Boolean(root.galleryPlay)))
              );
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
