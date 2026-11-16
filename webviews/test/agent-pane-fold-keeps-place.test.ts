// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Opening and closing a line in the transcript keeps the reader's place (Leo, ask-a736047107: "AND
// IT'S SO FUCKING AWKWARD TO SEE THEM THERE AT THE BOTTOM SINCE WHEN I EXPAND THEM IT JUMPS ME DOWN
// AND WHEN I COLLAPSE IT JUMPS ME UP"): the line clicked stays on its pixel while its panel opens
// under it, and again while it closes, at the transcript's end too, where the browser used to
// clamp the offset and bring every row down by what closed in one frame (foldAnchor.ts
// `foldRoomFor`). Near the end the line holds until the rows reach the view's end; from there the
// bottom is pinned and no blank room stays under the last row (Leo, 2026-11-07).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-fold-keeps-place.test.ts", async () => {
  const ENTRY = "agent-pane.incoming-message-disclosure";
  const VARIANT = "a-shipped";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("agent-pane-fold-keeps-place: skipping (run `bunx playwright install chromium`)");
    return;
  }
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
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The fanout-infra line (the long report, with a table): the whole line toggles on a click
  /// (AgentMessageRow.tsx); its chevron is the pointer's target, since an opened line's toggle
  /// button holds no words and has no box of its own.
  const lineOf = (page: Page) =>
    page.locator(".cv-received", { hasText: "fanout-infra" }).first().locator(":scope > .cv-agentmsg__line");
  const toggleOf = (page: Page) => lineOf(page).locator(".cv-agentmsg__chevron");
  const topOf = (page: Page) => lineOf(page).evaluate((node) => node.getBoundingClientRect().top);
  /// Every finite animation over (the fold), then the view at rest: the scroller's offset and
  /// height the same over STILL painted frames in a row, which outlasts the hold's last passes.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      const STILL = 16;
      for (let tries = 0; tries < 20; tries++) {
        const running = document
          .getAnimations()
          .filter((each) => each.effect?.getComputedTiming().endTime !== Infinity && each.playState === "running");
        if (running.length === 0) break;
        await Promise.all(running.map((each) => each.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
      }
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      let last = "";
      let still = 0;
      for (let frames = 0; frames < 240 && still < STILL; frames++) {
        await window.cmuxPaintFrame();
        const now = `${scroller?.scrollTop}:${scroller?.scrollHeight}`;
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });

  async function open(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    // The three delivered lines next to each other are one "Received 3 messages" row (#32720):
    // open it, so fanout-infra's line shows.
    const received = page.locator(".cv-lane-batch[data-kind='inbox'] .cv-lane-batch__toggle").first();
    await received.waitFor();
    if ((await received.getAttribute("aria-expanded")) === "false") await received.click();
    await toggleOf(page).waitFor();
    await settled(page);
    return page;
  }

  test("opening a line grows its panel under it; the line does not move", async () => {
    const page = await open();
    // Off the very bottom. At the very bottom an open grows down too (Codex parity,
    // transcript-expand-at-bottom.test.ts); this checks the plain case.
    const fromEnd = await page.locator(".acpmux-scroll").evaluate(async (node) => {
      node.scrollTop = Math.max(0, node.scrollHeight - node.clientHeight - 48);
      node.dispatchEvent(new Event("scroll"));
      await window.cmuxPaintFrame();
      return node.scrollHeight - node.clientHeight - node.scrollTop;
    });
    await settled(page);
    expect(fromEnd).toBeGreaterThan(8);
    const before = await topOf(page);
    await toggleOf(page).click();
    await page.locator(".cv-received__text table").waitFor();
    await settled(page);
    expect(Math.abs((await topOf(page)) - before)).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("closing a line near the transcript's end keeps it until the rows reach the end, then leaves no blank room", async () => {
    const page = await open();
    await toggleOf(page).click();
    await page.locator(".cv-received__text table").waitFor();
    await settled(page);
    // The reader scrolls the opened report's line to the view's top: closing it leaves less under
    // the view's top than the view is tall, which is where the browser clamped the offset.
    const scroller = page.locator(".acpmux-scroll");
    await scroller.evaluate((node) => {
      const line = node.querySelector<HTMLElement>(".cv-received__text")!.closest(".cv-received")!;
      node.scrollTop += line.getBoundingClientRect().top - node.getBoundingClientRect().top - 24;
    });
    await settled(page);
    const room = await scroller.evaluate((node) => {
      const panel = node.querySelector<HTMLElement>(".cv-received__text")!.getBoundingClientRect().height;
      return node.scrollHeight - node.scrollTop - node.clientHeight - panel;
    });
    // What closes is more than what lies below the view: holding the line through the whole close
    // would leave that much blank under the last row.
    expect(room).toBeLessThan(0);
    const rowHeight = () =>
      toggleOf(page).evaluate((node) => node.closest<HTMLElement>(".acpmux-row")!.getBoundingClientRect().height);
    const below = await scroller.evaluate((node) => node.scrollHeight - node.scrollTop - node.clientHeight);
    const tallBefore = await rowHeight();
    const before = await topOf(page);
    await toggleOf(page).click();
    await page.locator(".cv-received__text table").waitFor({ state: "detached" });
    await settled(page);
    const shortfall = tallBefore - (await rowHeight()) - below;
    expect(shortfall).toBeGreaterThan(0);
    // The line holds while the rows still reach the view's end (ask-a736047107: no clamp jump), then
    // comes down only by what would have been blank (Leo, 2026-11-07: the closed ones should
    // "remove the space at the bottom"), never up.
    const moved = (await topOf(page)) - before;
    expect(moved).toBeGreaterThanOrEqual(-1);
    expect(moved).toBeLessThanOrEqual(shortfall + 2);
    // At the end with nothing kept under the rows: scrolling up and back down finds the same end.
    const ends = await scroller.evaluate(async (node) => {
      const atEnd = node.scrollHeight - node.clientHeight - node.scrollTop;
      const tall = node.scrollHeight;
      node.scrollTop = 0;
      node.dispatchEvent(new Event("scroll"));
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
      return { atEnd, tall, now: node.scrollHeight };
    });
    expect(ends.atEnd).toBeLessThanOrEqual(1);
    expect(Math.abs(ends.now - ends.tall)).toBeLessThanOrEqual(1);
    await page.close();
  });
});
