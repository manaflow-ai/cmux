// cmux-web-test-timeout: 300
// Agent-pane gallery entries that had stopped showing the product (gallery sweep, 2026-10-20).
// Each must reach its state with real content: no play error, no stage that is blank or alone.
// Over 40 gallery stages, each about 1.5-2.5 s on a runner: the default 120 s ended the file
// mid-run (run 40693609653) with every case it reached green.
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
// Every play acts through `trustedGalleryInput`, the matrix runner's trusted mouse and keyboard
// (scripts/gallery-matrix/runner.ts), so a target the play cannot reach on screen fails here too.
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
  /** The page size, when the state breaks only in a smaller gallery-matrix frame (default 1000x800). */
  viewport?: { width: number; height: number };
  /** Drawn in the gallery health run's component frame at `viewport`'s size, as that run draws it. */
  frame?: "component";
  /** Modules (URL globs) that do not arrive until the stage has been read, as on a busy runner. */
  held?: string[];
};

await requireBrowserLane("gallery-agent-pane-entries.test.ts", async () => {
  /**
   * Installs the matrix runner's trusted input driver (`window.cmuxGalleryInput`) on a page before it
   * loads: play steps then click, hover and type through Playwright's mouse and keyboard at the
   * target's on-screen point, as in the gallery matrix, instead of the stage's synthetic DOM events.
   */
  const trustedGalleryInput = (page: Page) =>
    page.exposeFunction("cmuxGalleryInput", async (action: { kind: string; x?: number; y?: number; text?: string }) => {
      const { kind, x = 0, y = 0, text = "" } = action;
      if (kind === "click") await page.mouse.click(x, y);
      else if (kind === "hover" || kind === "move") await page.mouse.move(x, y);
      else if (kind === "down") {
        await page.mouse.move(x, y);
        await page.mouse.down();
      } else if (kind === "up") {
        await page.mouse.move(x, y);
        await page.mouse.up();
      } else if (kind === "contextmenu") await page.mouse.click(x, y, { button: "right" });
      else if (kind === "press") await page.keyboard.press(text);
      else if (kind === "type") await page.keyboard.type(text);
      else throw new Error(`gallery-agent-pane-entries: no trusted ${kind}`);
    });

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
    // No header tool draws a box in any state; the open panel's toggle is lit by its ink (Leo 2026-10-25).
    { entry: "header-tools", variant: "plain-icons", play: "error" },
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
    // Run boards: a person reviews a candidate's evidence and approves it for integration. Each is
    // "error", not "steps": its own labels change width when the state changes (a width follow-up,
    // not a missing state). Timeline: "Approve for integration" becomes "Approval recorded" and
    // shifts the review label. Compare (alone and in the tournament): the review state's words and
    // the approve button change width, and alone the right-aligned capture receipt grows, so its
    // anchor moves 92 px.
    { entry: "run-board-timeline", variant: "approved", play: "error", shows: has('[data-approved="attempt-a"]') },
    {
      entry: "run-board-tournament",
      variant: "approve-winner",
      play: "error",
      shows: has('[data-tournament-pane="compare"] [data-approved="attempt-a"]'),
    },
    {
      entry: "run-board-tournament",
      variant: "select-review",
      play: "error",
      shows: has('[data-tournament-pane="compare"] [data-review-state="reviewed"]'),
    },
    { entry: "run-board.compare", variant: "approve-winner", play: "error", shows: has('[data-approved="attempt-a"]') },
    // In the matrix's short frames the model menu scrolls and its last row, Fast mode, is half
    // clipped; the artifact panel's first Open preview is scrolled out above the latest reply.
    { entry: "composer-row", variant: "fast-off", play: "steps", viewport: { width: 720, height: 300 } },
    { entry: "composer-row", variant: "fast-on", play: "steps", viewport: { width: 720, height: 300 } },
    { entry: "composer-pickers", variant: "fast-mode", play: "steps", viewport: { width: 640, height: 260 } },
    // "error", not "steps": the panel opens beside the chat and narrows it, a layout shift by design.
    {
      entry: "artifact-panel",
      variant: "versions",
      play: "error",
      viewport: { width: 760, height: 640 },
      shows: has(".acpmux-artifact .acpmux-artifact-versions"),
    },
    // The transcript opens at its end, so the first reply image, the one these plays click, is
    // above the fold.
    ...["open", "dismiss-and-restore"].map((variant): Case => ({ entry: "image-viewer", variant, play: "steps" })),
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
    // A reply's Markdown or HTML fence, first draft or rewrite, opens beside the chat from its code
    // card's Open preview, at the health run's frame (normal width, the entry's 640 px). The
    // highlighted card's chunk loads after the page's first frame (CodeBlock.tsx); until it does,
    // the plain card must offer Open preview too, or a play on a busy runner finds no button.
    ...["markdown", "html", "versions"].map((variant): Case => ({
      entry: "artifact-panel",
      variant,
      play: "error",
      viewport: { width: 760, height: 640 },
      frame: "component",
      held: ["**/conversation/HighlightedCode.tsx*"],
      shows: has(".acpmux-artifact"),
    })),
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
  const url = ({ entry, variant, viewport, frame }: Case) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(
      `agent-pane.${entry}`,
      frame ? { variant, frame, ...viewport } : { variant },
    )}`;

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
      const page = await browser!.newPage({ viewport: item.viewport ?? { width: 1000, height: 800 } });
      await trustedGalleryInput(page);
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      const held: (() => Promise<void>)[] = [];
      for (const glob of item.held ?? [])
        await page.route(glob, (route) => void held.push(() => route.continue().catch(() => undefined)));
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
      await Promise.all(held.map((release) => release()));
      await page.close();
      expect(errors).toEqual([]);
      expect(ready).toBe("1");
      if (item.play === "steps") expect(playFailures(report)).toEqual([]);
      if (item.play === "error") expect((JSON.parse(report) as { error?: string }).error).toBeUndefined();
      expect(shows, report).toBe(true);
    });
});
