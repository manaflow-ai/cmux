import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("summary-header-paint.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({ configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"), server: { host: "127.0.0.1", port: 0, strictPort: false, watch: null }, logLevel: "error" });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.summary-header", { browser, params: { variant: "commands-and-failure" } });
  });
  afterAll(async () => { await browser?.close(); await vite?.close(); });
  for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
    test(`summary header paint and first glyph: ${theme}`, async () => {
      const page = await browser.newPage({ viewport: { width: 1600, height: 640 } });
      try {
        await installPaintedFrames(page);
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-header", { variant: "commands-and-failure", theme })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator('.acpmux-summary-card[data-placement="inline"] .acpmux-summary-card__counts').waitFor();
        await page.evaluate(() => document.fonts.ready);
        await page.evaluate(() => {
          const reports: number[] = [];
          (window as unknown as { __tabRowWidths: number[] }).__tabRowWidths = reports;
          window.cmuxAcpmuxActions = {
            ...window.cmuxAcpmuxActions,
            "pane.tabRowTools": async (params) => { reports.push(Number(params.width)); return null; },
          };
          window.cmuxAcpmuxBridge!.applyTabRow!({ height: 28, trailingInset: 40 });
        });
        await page.locator(".acpmux-header[data-tab-row]").waitFor();
        await page.waitForFunction(() => (window as unknown as { __tabRowWidths: number[] }).__tabRowWidths.some((width) => width > 0));
        const receipt = await page.evaluate(async () => {
          await window.cmuxPaintFrame();
          await window.cmuxPaintFrame();
          const counts = document.querySelector<HTMLElement>(".acpmux-summary-card__counts")!;
          const range = document.createRange();
          range.setStart(counts.firstChild!, 0);
          range.setEnd(counts.firstChild!, 1);
          const glyph = range.getBoundingClientRect();
          const hit = document.elementFromPoint(glyph.x + glyph.width / 2, glyph.y + glyph.height / 2);
          const selectors = [".acpmux-shell", ".acpmux-summary-card", ".acpmux-summary-card__head", ".acpmux-summary-card__counts", ".acpmux-handoff-header-tools", ".acpmux-header-tools", ".acpmux-running-tray"];
          const shell = document.querySelector<HTMLElement>(".acpmux-shell")!.getBoundingClientRect();
          const reportedWidths = (window as unknown as { __tabRowWidths: number[] }).__tabRowWidths;
          const reportedWidth = reportedWidths.at(-1)!;
          // Project the host's nativeRects into CSS pixels (AgentPaneTabRow.swift nativeHoles).
          // Chromium alone cannot apply the AppKit window's holes, so the receipt distinguishes
          // normal DOM hit testing from the same glyph's visibility through the native aperture.
          const room = Math.max(0, shell.width - 40);
          const aperture = { left: shell.left + room - Math.min(Math.max(0, reportedWidth), room / 2), right: shell.left + room, bottom: shell.top + 28 };
          const tools = document.querySelector<HTMLElement>(".acpmux-handoff-header-tools")!.getBoundingClientRect();
          return {
            reportedWidths,
            aperture,
            firstGlyphVisibleThroughNativeRow: glyph.top >= aperture.bottom || (glyph.left >= aperture.left && glyph.right <= aperture.right),
            toolsVisibleThroughNativeRow: tools.left >= aperture.left && tools.right <= aperture.right,
            text: counts.textContent,
            firstGlyphVisible: !!hit && counts.contains(hit),
            glyph: glyph.toJSON(),
            nodes: selectors.map((selector) => {
              const node = document.querySelector<HTMLElement>(selector);
              if (!node) return { selector, missing: true };
              const style = getComputedStyle(node);
              return { selector, rect: node.getBoundingClientRect().toJSON(), scrollLeft: node.scrollLeft, background: style.background, backgroundColor: style.backgroundColor, backgroundImage: style.backgroundImage, backdrop: style.backdropFilter, mask: style.maskImage, shadow: style.boxShadow, radius: style.borderRadius, overflow: style.overflow };
            }),
          };
        });
        console.log("SUMMARY_PAINT_RECEIPT=" + JSON.stringify(receipt));
        if (process.env.SUMMARY_PAINT_CAPTURE === "1") {
          console.log("SUMMARY_PAINT_PNG=" + JSON.stringify({ theme, kind: "web-content", data: (await page.screenshot()).toString("base64") }));
          await page.evaluate(({ left, right, bottom }) => {
            for (const [x, width] of [[0, left], [right, innerWidth - right]]) {
              const hole = document.createElement("div");
              hole.dataset.nativeHoleProjection = "";
              Object.assign(hole.style, { position: "fixed", left: `${x}px`, top: "0", width: `${width}px`, height: `${bottom}px`, zIndex: "2147483647", background: "var(--agent-page-bg)" });
              document.body.append(hole);
            }
          }, receipt.aperture);
          console.log("SUMMARY_PAINT_PNG=" + JSON.stringify({ theme, kind: "native-hole-projection", data: (await page.screenshot()).toString("base64") }));
        }
        for (const selector of [".acpmux-handoff-header-tools", ".acpmux-header-tools"]) {
          const node = receipt.nodes.find((node) => node.selector === selector);
          expect(node && "backgroundColor" in node && node.backgroundColor).toBe("rgba(0, 0, 0, 0)");
          expect(node && "backgroundImage" in node && node.backgroundImage).toBe("none");
          expect(node && "backdrop" in node && node.backdrop).toBe("none");
          expect(node && "mask" in node && node.mask).toBe("none");
        }
        expect(receipt.text).toContain("2 commands · 1 failed");
        expect(receipt.firstGlyphVisible).toBe(true);
        expect(receipt.firstGlyphVisibleThroughNativeRow).toBe(true);
        expect(receipt.toolsVisibleThroughNativeRow).toBe(true);
      } catch (error) {
        console.log("SUMMARY_FAILURE_STATE=" + JSON.stringify(await page.evaluate(() => ({ text: document.body.innerText.slice(0, 1600), shell: document.querySelector(".acpmux-shell")?.getBoundingClientRect().toJSON(), card: document.querySelector(".acpmux-summary-card")?.outerHTML.slice(0, 400) }))));
        throw error;
      } finally { await page.close(); }
    });
  }
});
