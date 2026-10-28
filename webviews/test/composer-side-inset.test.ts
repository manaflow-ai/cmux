// cmux-web-test-timeout: 300
// The composer's left and right insets (Leo 2026-10-21: "STOP WITH THE INCESSANT LEFT RIGHT
// PADDING"). As Claude Code lays it out, the composer box spans the transcript's text column, and the
// quiet row under it starts and ends on the box's edges: its first control's pill at the box's left
// edge, its last control's at the box's right edge. cmux inset the row 13 px on the left and 10 px
// on the right of the box (composerLocation.css, .acpmux-composer-foot), and the New Tab page kept
// its composer to a 720 px column while the chat's widens to 800 px on a wide pane (the chat column,
// --cv-column, conversation.css), so on a wide pane the New Tab box sat 40 px further in on each side.
//
// - The chat pane, idle and with a turn running, at a narrow, a normal and a wide pane: the box's
//   edges are the transcript column's, and the quiet row's first and last controls sit on them.
// - The New Tab page, every template (Cards had its own 880 px column, the Classic page 760 px):
//   the box takes the chat's column at every width, and the row ends on its right edge.
//
// Real Chromium and WebKit on the gallery stage. CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-side-inset.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-side-inset.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-side-inset: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer side inset", () => test("browsers", () => {}));
    return;
  }

  const CHAT = "agent-pane.composer-row";
  const NEW_TAB = "agent-pane.new-tab";
  /** Each template's gallery state and its box. */
  const NEW_TAB_TEMPLATES: [string, string, string][] = [
    ["minimal", "minimal-default", ".nt-box"],
    ["default", "reasoning-chip-stage", ".nt-box"],
    ["cards", "template-cards", ".nt-box"],
    ["composer", "template-composer", ".nt-box"],
    ["threads", "template-threads", ".nt-box"],
    ["console", "template-console", ".nt-box"],
    ["classic", "template-classic", ".acpmux-newtab-box"],
  ];
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const open = async (engine: string, entry: string, variant: string, width: number) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    // The Default template keeps its chips in the box (no quiet row); the Classic page has none.
    await page.locator(".acpmux-composer-foot button:visible, .nt-box, .acpmux-newtab-box").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, CHAT, { browser, params: { variant: "claude-auto" } });
    await warmGalleryFrame(vite, NEW_TAB, { browser, params: { variant: "minimal-default" } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** The box, the quiet row's outermost controls and (in a chat) the transcript's column. */
  const measure = (page: Page, box: string) =>
    page.evaluate((box) => {
      const card = document.querySelector(box)!.getBoundingClientRect();
      const controls = [...document.querySelectorAll(".acpmux-composer-foot :is(button, .acpmux-picker-button)")]
        .map((button) => button.getBoundingClientRect())
        .filter((rect) => rect.width > 0);
      const rows = [...document.querySelectorAll(".acpmux-scroll .acpmux-row")]
        .map((row) => row.getBoundingClientRect())
        .filter((rect) => rect.width > 0);
      const screen = document.querySelector(".nt-screen, .acpmux-newtab");
      return {
        box: { left: card.left, right: card.right },
        first: Math.min(...controls.map((rect) => rect.left)),
        last: Math.max(...controls.map((rect) => rect.right)),
        column: rows.length
          ? { left: Math.min(...rows.map((rect) => rect.left)), right: Math.max(...rows.map((rect) => rect.right)) }
          : null,
        page: screen ? { left: screen.getBoundingClientRect().left, width: screen.clientWidth } : null,
      };
    }, box);

  for (const [engine] of engines) {
    for (const variant of ["claude-auto", "queued"])
      for (const width of [420, 760, 1100])
        test(`${engine}: chat ${variant} at ${width} px: the box spans the transcript's column, the row its edges`, async () => {
          const page = await open(engine, CHAT, variant, width);
          const at = await measure(page, ".acpmux-composer-box");
          await page.close();
          expect(at.column, "the transcript draws rows").not.toBeNull();
          expect(Math.abs(at.box.left - at.column!.left), "the box's left edge on the column's").toBeLessThanOrEqual(
            0.5,
          );
          expect(Math.abs(at.box.right - at.column!.right), "the box's right edge on the column's").toBeLessThanOrEqual(
            0.5,
          );
          expect(
            Math.abs(at.first - at.box.left),
            "the row's first control on the box's left edge",
          ).toBeLessThanOrEqual(0.5);
          expect(
            Math.abs(at.box.right - at.last),
            "the row's last control on the box's right edge",
          ).toBeLessThanOrEqual(0.5);
        });

    // Every New Tab template (templates.ts), Cards and the Classic page included, takes the chat's
    // column: none keeps a column of its own (Cards had 880 px, Classic 760 px, the rest 720 px).
    for (const [template, variant, box] of NEW_TAB_TEMPLATES)
      for (const width of [420, 760, 1400, 1600])
        test(`${engine}: New Tab ${template} at ${width} px: the box takes the chat's column, the row ends on its edge`, async () => {
          const page = await open(engine, NEW_TAB, variant, width);
          const at = await measure(page, box);
          await page.close();
          // The chat's column (conversation.css --cv-column, --cv-inset): 720 px, widening to 800 px
          // at 62.5% of a wide pane, never nearer the sides than the 18 px page edge.
          const column = Math.min(800, Math.max(720, at.page!.width * 0.625));
          const inset = Math.max(18, (at.page!.width - column) / 2);
          expect(
            Math.abs(at.box.left - (at.page!.left + inset)),
            "the box's left edge on the chat's column",
          ).toBeLessThanOrEqual(1);
          expect(
            Math.abs(at.page!.left + at.page!.width - inset - at.box.right),
            "the box's right edge on the chat's column",
          ).toBeLessThanOrEqual(1);
          // The Default template and the Classic page have no quiet row.
          if (Number.isFinite(at.last))
            expect(
              Math.abs(at.box.right - at.last),
              "the row's last control on the box's right edge",
            ).toBeLessThanOrEqual(0.5);
        });
  }
});
