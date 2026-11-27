// A line cut to N lines shows N lines and no sliver of the next (Leo, 2026-11-23, on a folded
// thought row: "the additional line things we need to just... not show the sliver of the second
// line."). `overflow: hidden` clips at the padding edge, so padding on a clamped box shows the top of
// the line after the last one it keeps. The room around such a line is a transparent border.
//
// On the gallery stage, in real Chromium and WebKit: every clamped box on the page (computed
// `-webkit-line-clamp` set, overflow clipped; Chromium computes the display as flow-root) whose words run past its lines clips to exactly its lines,
// its padding box no taller than the lines it keeps.
//
// Locally: CMUX_BROWSER_TESTS=1 bun test test/line-clamp-no-sliver.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("line-clamp-no-sliver.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`line-clamp-no-sliver: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("line clamp no sliver", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.thought-shapes", {
      browser: browsers.get("chromium") ?? browsers.get("webkit"),
      params: { variant: "wrapping-line" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  for (const [engine] of engines)
    test(`${engine}: a folded thought's line shows no sliver of its second line`, async () => {
      const page = await browsers.get(engine)!.newPage({ viewport: { width: 520, height: 900 } });
      try {
        await page.goto(stageURL("agent-pane.thought-shapes", "wrapping-line", 520));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.evaluate(() => document.fonts.ready);
        // The thought sits inside the turn's worked group: open the group so its row is on the page.
        const group = page.locator("button.cv-worked.is-toggle").last();
        if ((await group.count()) && (await group.getAttribute("aria-expanded")) !== "true") await group.click();
        await page.locator(".cv-thought .cv-thought__preview").first().waitFor({ state: "visible" });
        const boxes = await page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement>("*")].flatMap((node) => {
            const style = getComputedStyle(node);
            const clamp = Number.parseInt(style.getPropertyValue("-webkit-line-clamp"), 10);
            if (!(clamp > 0) || style.overflowY === "visible") return [];
            // Only a box whose words run past the lines it keeps has a next line to show.
            if (node.scrollHeight <= node.clientHeight + 1) return [];
            const pitch = Number.parseFloat(style.lineHeight);
            return [
              {
                box: `${node.tagName.toLowerCase()}.${[...node.classList].join(".")}`,
                clip: node.clientHeight,
                lines: clamp * pitch,
              },
            ];
          }),
        );
        expect(boxes.some((b) => b.box.includes("cv-thought__preview"))).toBe(true);
        // The padding box (what overflow clips to) is the kept lines, no more: nothing of the next one.
        for (const b of boxes)
          expect({ box: b.box, clip: Math.round(b.clip) }).toEqual({ box: b.box, clip: Math.round(b.lines) });
      } finally {
        await page.close();
      }
    });
});
