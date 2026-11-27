// l10n-allow-file: gallery fixture names are test data.
// A received message's line keeps its sender, its machine ("m5pro-24…"), its first line, its chevron,
// Reply and its time on one centre line. Leo, 2026-11-27, on "…. ⌄  Reply 3 minutes ago" and
// "m5pro-24.... ⌄": "why is this misaligned let's prevent misalignment ... like this misaligned text
// here", and "let's also just do a proper 'it shows all the way, and when you hover it pushes to the
// left maybe?".
//
// Real Chromium (Playwright), the gallery's `agent-pane.remote-sender` (the sender on another machine),
// wide and narrow: each part's glyphs (a Range over its text, so a line-height or font-size that
// differs shows as it does on screen) and the chevron's box centre on the sender's name within 0.5px,
// at rest and with the line hovered (Reply shown). With CMUX_TEST_ARTIFACTS set, each case leaves a
// screenshot of the line there.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("received-line-align.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.remote-sender";
  const TOLERANCE = 0.5;
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
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "machine" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const LINE = ".cv-received > .cv-agentmsg__line";

  const open = async (variant: string, width: number): Promise<Page> => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width, height: 420 }, deviceScaleFactor: 2 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width, height: 420 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForSelector(`${LINE} .cv-received__from`);
    await page.waitForTimeout(300);
    return page;
  };

  /** Each part's vertical centre less the sender name's glyph centre, the first received line's. */
  const offsets = (page: Page) =>
    page.evaluate((lineSelector) => {
      const line = document.querySelector<HTMLElement>(lineSelector)!;
      const glyphMiddle = (node: Element | null) => {
        if (!node) return undefined;
        const range = document.createRange();
        range.selectNodeContents(node);
        const rects = [...range.getClientRects()].filter((rect) => rect.width > 0 && rect.height > 0);
        if (rects.length === 0) return undefined;
        return (Math.min(...rects.map((rect) => rect.top)) + Math.max(...rects.map((rect) => rect.bottom))) / 2;
      };
      const boxMiddle = (node: Element | null) => {
        const rect = node?.getBoundingClientRect();
        return rect && rect.height > 0 ? rect.top + rect.height / 2 : undefined;
      };
      const shown = (node: Element | null) =>
        node && Number.parseFloat(getComputedStyle(node).opacity) > 0.5 ? node : null;
      const name = glyphMiddle(line.querySelector(".cv-received__from"))!;
      const parts: [string, number | undefined][] = [
        ["machine", glyphMiddle(line.querySelector(".cv-received__host-name, .cv-received__host"))],
        ["first line", glyphMiddle(line.querySelector(".cv-agentmsg__preview"))],
        ["chevron", boxMiddle(line.querySelector(".cv-agentmsg__chevron svg"))],
        ["Reply", glyphMiddle(shown(line.querySelector(".cv-received__reply")))],
        ["time", glyphMiddle(shown(line.querySelector(".cv-received__hover .cv-turn-time")))],
      ];
      const host = line.querySelector<HTMLElement>(".cv-received__host");
      return {
        host: host ? { shown: host.clientWidth, whole: host.scrollWidth } : null,
        off: Object.fromEntries(
          parts.flatMap(([part, middle]) => (middle === undefined ? [] : [[part, middle - name]])),
        ) as Record<string, number>,
      };
    }, LINE);

  const shoot = async (page: Page, name: string) => {
    const dir = process.env.CMUX_TEST_ARTIFACTS;
    if (!dir) return;
    const box = await page.locator(LINE).first().boundingBox();
    if (!box) return;
    await page.screenshot({
      path: path.join(dir, `received-line-${name}.png`),
      clip: { x: 0, y: Math.max(0, box.y - 10), width: page.viewportSize()!.width, height: box.height + 20 },
    });
  };

  for (const variant of ["machine", "named"])
    for (const width of [760, 360])
      test(`${variant} at ${width}px: sender, machine, first line, chevron, Reply and time on one centre line`, async () => {
        const page = await open(variant, width);
        try {
          const rest = await offsets(page);
          await shoot(page, `${variant}-${width}`);
          await page.locator(LINE).first().hover();
          await page.waitForTimeout(400);
          const hovered = await offsets(page);
          await shoot(page, `${variant}-${width}-hover`);
          const report = `${variant} ${width}px: rest ${JSON.stringify(rest)} hovered ${JSON.stringify(hovered)}`;
          console.log(report);
          if (variant === "machine") expect(Object.keys(rest.off), report).toContain("machine");
          for (const [when, measured] of [
            ["at rest", rest],
            ["hovered", hovered],
          ] as const)
            for (const [part, off] of Object.entries(measured.off))
              expect(
                Math.abs(off),
                `${part} ${when} off the name's centre by ${off.toFixed(2)}px; ${report}`,
              ).toBeLessThanOrEqual(TOLERANCE);
        } finally {
          await page.close();
        }
      });

  test("a cut machine name scrolls left to its end while the pointer rests on it, and back when it leaves", async () => {
    const page = await open("machine", 760);
    try {
      // A line too short for the machine's whole name: its box is held to 40px, as a narrow pane cuts it.
      const host = page.locator(`${LINE} .cv-received__host`).first();
      await host.evaluate((node) => {
        (node as HTMLElement).style.maxWidth = "40px";
      });
      const cut = await host.evaluate((node) => node.scrollWidth - node.clientWidth);
      expect(cut).toBeGreaterThan(2);
      await host.hover();
      // The tabs' clock (ui/titleFade.ts MOTION_MARQUEE): 0.6s at rest, then 40px/s.
      await page.waitForTimeout(1100);
      const moving = await host.evaluate((node) => ({
        marquee: (node as HTMLElement).dataset.marquee !== undefined,
        indent: Number.parseFloat(getComputedStyle(node).textIndent) || 0,
        ellipsis: getComputedStyle(node).textOverflow,
      }));
      await shoot(page, "machine-marquee");
      expect(moving.marquee).toBe(true);
      expect(moving.indent).toBeLessThan(-2);
      expect(moving.ellipsis).toBe("clip");
      // Off the line: 30px above or below it.
      const line = (await page.locator(LINE).first().boundingBox())!;
      await page.mouse.move(2, line.y > 40 ? line.y - 30 : line.y + line.height + 30);
      await page.waitForTimeout(900);
      const back = await host.evaluate((node) => ({
        marquee: (node as HTMLElement).dataset.marquee !== undefined,
        indent: Number.parseFloat(getComputedStyle(node).textIndent) || 0,
        ellipsis: getComputedStyle(node).textOverflow,
      }));
      expect(back).toEqual({ marquee: false, indent: 0, ellipsis: "ellipsis" });
    } finally {
      await page.close();
    }
  });
});
