// cmux-web-test-timeout: 300
// The space under the composer's quiet row (Leo 2026-10-21: "WE HAVE TOO MUCH ... SPACE AT THE
// BOTTOM COMPARED TO CLAUDE CODE"). Claude Code's composer box is followed by its one footer row
// (the mode, then the model button and the context ring), and that row sits at the window's
// bottom edge with only a few px under it. cmux drew a band about as tall as the row itself under
// it: the row's own 10 px margin and the composer form's 16 px bottom padding (styles.css), and on
// the New Tab page's stage the page's 16 px bottom padding in the form's place.
//
// In the chat pane, idle and with a turn running (a queue over the box), and on the New Tab page's
// stage (Minimal with its widgets on and the template dots off, the composer at the page's foot): the row's bottom sits at
// most 8 px above the pane's bottom edge (Claude Code leaves about 8), and its controls keep at least 2 px of it, so a focus
// outline or a hover pill still draws whole.
//
// Real Chromium and WebKit on the gallery stage. CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-bottom-space.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-bottom-space.test.ts", async () => {
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
      console.warn(`composer-bottom-space: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer bottom space", () => test("browsers", () => {}));
    return;
  }

  type Stage = { name: string; entry: string; variant: string; pane: string; height: number };
  const STAGES: Stage[] = [
    {
      name: "chat pane, idle",
      entry: "agent-pane.composer-row",
      variant: "claude-auto",
      pane: ".acpmux-main",
      height: 480,
    },
    {
      name: "chat pane, turn running",
      entry: "agent-pane.composer-row",
      variant: "queued",
      pane: ".acpmux-main",
      height: 480,
    },
    {
      name: "New Tab stage",
      entry: "agent-pane.new-tab",
      variant: "minimal-stage-foot",
      pane: ".nt-screen",
      height: 640,
    },
  ];

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (stage: Stage) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(stage.entry, { variant: stage.variant })}`;

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
    for (const stage of [...STAGES, dotsStage])
      await warmGalleryFrame(vite, stage.entry, { browser, params: { variant: stage.variant } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  for (const [engine] of engines)
    for (const stage of STAGES)
      for (const width of [420, 760])
        test(`${engine}: ${stage.name} at ${width} px: the quiet row sits a few px over the pane's bottom edge`, async () => {
          const page = await browsers.get(engine)!.newPage({ viewport: { width, height: stage.height } });
          await page.goto(stageURL(stage));
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          await page.locator(".acpmux-composer-foot button:visible").first().waitFor();
          await page.evaluate(() => document.fonts.ready);
          const drawn = await page.evaluate((paneSelector) => {
            const foot = document.querySelector(".acpmux-composer-foot")!;
            const pane = document.querySelector(paneSelector)!.getBoundingClientRect();
            const edge = Math.min(pane.bottom, window.innerHeight);
            const controls = [...foot.querySelectorAll("button")]
              .map((button) => button.getBoundingClientRect())
              .filter((rect) => rect.height > 0);
            return {
              row: edge - foot.getBoundingClientRect().bottom,
              controls: edge - Math.max(...controls.map((rect) => rect.bottom)),
            };
          }, stage.pane);
          await page.close();
          expect(drawn.row, "the row ends inside the pane").toBeGreaterThanOrEqual(-0.5);
          expect(drawn.row, "a few px under the row, as Claude Code's").toBeLessThanOrEqual(8);
          expect(drawn.controls, "room for a control's focus outline").toBeGreaterThanOrEqual(2);
        });

  // The template dots (a widget, off by default) sit absolutely at the page's foot: with them on,
  // the page keeps its band, so the quiet row never draws over them.
  const dotsStage: Stage = {
    name: "New Tab stage with the template dots",
    entry: "agent-pane.new-tab",
    variant: "minimal-widgets",
    pane: ".nt-screen",
    height: 640,
  };
  for (const [engine] of engines)
    test(`${engine}: ${dotsStage.name}: the quiet row stays clear of the dots`, async () => {
      const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: dotsStage.height } });
      await page.goto(stageURL(dotsStage));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      // The templates group, not the composer look dots (#24367), which share its class.
      await page.getByRole("group", { name: "New Tab templates" }).waitFor();
      await page.locator(".acpmux-composer-foot button:visible").first().waitFor();
      const drawn = await page.evaluate(() => ({
        foot: document.querySelector(".acpmux-composer-foot")!.getBoundingClientRect().bottom,
        dots: document.querySelector(".nt-style:not(.nt-look-dots) .nt-style-options")!.getBoundingClientRect().top,
      }));
      await page.close();
      expect(drawn.foot, "the row ends over the dots").toBeLessThanOrEqual(drawn.dots + 0.5);
    });
});
