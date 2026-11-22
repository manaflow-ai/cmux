// l10n-allow-file: gallery fixture names are test data.
// The composer hat's header draws every icon and its text on one centre line (cmux#49587: "this icon
// is misaligned vertically we need to center this", of the folded strip "1 build · 1 subagent done
// 7m 32s"). The side-panel button lay over the header in a 28px box pinned to its top, while the
// header itself is 34px (the `roomy` arm, trayHeadHeight.experiment.ts), so its icon sat 3px above
// the chevron and the counts. Now the header, the panel button and the `hide` button share one
// height (`--acpmux-tray-head-height`, subagents.css).
//
// Real Chromium (Playwright), the gallery's `agent-pane.subagent-tray-kinds` folded: the centre of
// every kind mark (the hammer, the done check), every count's text, the panel icon and the chevron
// against the header's own centre, at Compact, Default and Spacious, a grown Text Size, and each
// header height; the panel icon and the chevron also draw at one size.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-hat-head-centre-line-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.subagent-tray-kinds";
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "folded" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  /** The host's scales for each density (DesignSettings.interfaceScaleScript), and a grown Text Size. */
  const densities = {
    compact: { interface: 1, densityText: 0.9, chat: 1 },
    default: { interface: 1, densityText: 1, chat: 1 },
    spacious: { interface: 1.2, densityText: 1.2, chat: 1 },
    "text size": { interface: 1.2, densityText: 1.2, chat: 1.2 },
  } as const;

  /** Each part's vertical centre less the header's, and the panel icon's and chevron's sizes. */
  const measure = (page: Page) =>
    page.evaluate(() => {
      const head = document.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
      const box = head.getBoundingClientRect();
      const mid = box.top + box.height / 2;
      const off = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return Math.round((rect.top + rect.height / 2 - mid) * 100) / 100;
      };
      const size = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return { width: rect.width, height: rect.height };
      };
      const panel = document.querySelector(".acpmux-running-tray__open > svg")!;
      const chevron = document.querySelector(".acpmux-running-tray__chevron > svg")!;
      const marks = [...head.querySelectorAll(".acpmux-running-tray__kind > svg, .acpmux-lineage__icon")];
      const texts = [...head.querySelectorAll(".acpmux-running-tray__kind-text, .acpmux-running-tray__time")];
      return {
        height: box.height,
        panel: off(panel),
        chevron: off(chevron),
        marks: marks.map(off),
        texts: texts.map(off),
        panelSize: size(panel),
        chevronSize: size(chevron),
      };
    });

  for (const [density, scales] of Object.entries(densities))
    for (const headHeight of ["row", "roomy", "tall"])
      test(`${density}, ${headHeight} header: icons and text share the header's centre line`, async () => {
        const port = (server.httpServer!.address() as { port: number }).port;
        const page = await browser.newPage({ viewport: { width: 760, height: 640 }, deviceScaleFactor: 2 });
        try {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "folded" })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.waitForSelector(".acpmux-running-tray__open > svg");
          await page.evaluate(
            ({ s, headHeight }) => {
              const root = document.documentElement.style;
              root.setProperty("--cmux-interface-scale", String(s.interface));
              root.setProperty("--cmux-density-text-scale", String(s.densityText));
              root.setProperty("--cmux-chat-text-scale", String(s.chat));
              document.querySelector<HTMLElement>(".acpmux-running-tray")!.dataset.headHeight = headHeight;
            },
            { s: scales, headHeight },
          );
          await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
          const at = await measure(page);
          const report = JSON.stringify(at);
          expect(at.marks.length, report).toBeGreaterThan(0);
          expect(at.texts.length, report).toBeGreaterThan(0);
          // The case in the issue: the panel icon on the chevron's line, and both on the header's.
          expect(Math.abs(at.panel), report).toBeLessThanOrEqual(0.5);
          expect(Math.abs(at.chevron), report).toBeLessThanOrEqual(0.5);
          expect(Math.abs(at.panel - at.chevron), report).toBeLessThanOrEqual(0.5);
          for (const mark of at.marks) expect(Math.abs(mark), report).toBeLessThanOrEqual(0.5);
          for (const text of at.texts) expect(Math.abs(text), report).toBeLessThanOrEqual(1);
          // One size for the two trailing controls' glyphs.
          expect(at.panelSize, report).toEqual(at.chevronSize);
        } finally {
          await page.close();
        }
      });
});
