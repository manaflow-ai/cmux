// A session reference's hover card (started/SessionHoverCard.tsx) over the transcript (Leo,
// 2026-10-20, "the styling is a bit shit"; references: Claude desktop's and Codex's hover and link
// previews):
//   - its surface is the popup surface every hover card, menu and popover uses, never a grey that
//     reads as the user bubble beside it;
//   - a hairline rim and the hover card elevation (--elevation-2), nothing more dramatic;
//   - proper padding, and a hierarchy: the title (emphasis), then the status row, then the meta line
//     (folder and branch) in a smaller, muted ink.
// Measured in light and dark from the gallery's `reply` variant, which sets the card beside a user
// bubble as the app shows it. Real Chromium from Playwright; CI fails the file when it cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Box = { left: number; top: number; right: number; bottom: number };
type Measured = {
  card: Box;
  bubble: Box;
  title: Box;
  status: Box;
  meta: Box | null;
  border: { width: number; color: string };
  shadow: string;
  elevation: string;
  titleWeight: string;
  titleSize: string;
  titleColor: string;
  metaSize: string | null;
  metaColor: string | null;
  bodySize: string;
};

await requireBrowserLane("session-hover-card-surface.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("session-hover-card-surface: skipping (run `bunx playwright install chromium`)");
    describe.skip("session hover card surface", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(colorScheme: "light" | "dark"): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 720, height: 400 }, colorScheme });
    for (;;) {
      try {
        await page.goto(
          `http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.session-hover&variant=reply&frame=component&width=560&colorScheme=${colorScheme}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.locator(".acpmux-session-hover-card .acpmux-session-hover-title").waitFor();
    await page.mouse.move(0, 0);
    return page;
  }

  /** Runs in the page. */
  function measure(): Measured {
    const box = (element: Element | null): Box | null => {
      if (!element) return null;
      const r = element.getBoundingClientRect();
      return { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
    };
    const card = document.querySelector(".acpmux-session-hover-card")!;
    const style = getComputedStyle(card);
    // What `--elevation-2` resolves to here, through the same cascade the card sits in.
    const probe = document.createElement("div");
    probe.style.boxShadow = "var(--elevation-2)";
    card.parentElement!.append(probe);
    const elevation = getComputedStyle(probe).boxShadow;
    probe.remove();
    const title = card.querySelector(".acpmux-session-hover-title")!;
    const meta = card.querySelector(".acpmux-session-hover-meta");
    return {
      card: box(card)!,
      bubble: box(document.querySelector(".acpmux-user-bubble"))!,
      title: box(title)!,
      status: box(card.querySelector(".acpmux-session-status-line"))!,
      meta: box(meta),
      border: { width: parseFloat(style.borderTopWidth) || 0, color: style.borderTopColor },
      shadow: style.boxShadow,
      elevation,
      titleWeight: getComputedStyle(title).fontWeight,
      titleSize: getComputedStyle(title).fontSize,
      titleColor: getComputedStyle(title).color,
      metaSize: meta ? getComputedStyle(meta).fontSize : null,
      metaColor: meta ? getComputedStyle(meta).color : null,
      bodySize: (() => {
        const step = document.createElement("span");
        step.style.fontSize = "var(--text-body)";
        card.parentElement!.append(step);
        const size = getComputedStyle(step).fontSize;
        step.remove();
        return size;
      })(),
    };
  }

  /** The page's pixels, and one pixel of them (CSS px; the page is 1x). */
  async function pixels(page: Page) {
    const png = PNG.sync.read(await page.screenshot());
    return (x: number, y: number) => {
      const i = (Math.round(y) * png.width + Math.round(x)) * 4;
      return [png.data[i]!, png.data[i + 1]!, png.data[i + 2]!];
    };
  }
  const distance = (a: number[], b: number[]) => Math.hypot(a[0]! - b[0]!, a[1]! - b[1]!, a[2]! - b[2]!);

  /** The popup surface's color here, painted on a probe beside the card. */
  async function popupSurface(page: Page) {
    await page.evaluate(() => {
      const probe = document.createElement("div");
      probe.id = "popup-probe";
      probe.className = "ui-positioner";
      probe.style.cssText = "position:fixed;left:680px;top:360px;width:30px;height:30px;background:var(--surface-popup)";
      document.querySelector(".acpmux-shell")!.append(probe);
    });
    const pixel = await pixels(page);
    const color = pixel(695, 375);
    await page.evaluate(() => document.getElementById("popup-probe")?.remove());
    return color;
  }

  for (const scheme of ["light", "dark"] as const) {
    describe(`${scheme}`, () => {
      test("the card is the popup surface, and does not read as the user bubble", async () => {
        const page = await open(scheme);
        const m = await page.evaluate(measure);
        const pixel = await pixels(page);
        // Inside the rim, in the top padding, clear of the text.
        const fill = pixel(m.card.right - 6, m.card.top + 4);
        const bubble = pixel(m.bubble.left + 4, (m.bubble.top + m.bubble.bottom) / 2);
        const surface = await popupSurface(page);
        await page.close();
        expect(distance(fill, surface)).toBeLessThanOrEqual(3);
        expect(distance(fill, bubble)).toBeGreaterThanOrEqual(12);
      });

      test("a hairline rim and the hover card elevation", async () => {
        const page = await open(scheme);
        const m = await page.evaluate(measure);
        const pixel = await pixels(page);
        const fill = pixel(m.card.right - 6, m.card.top + 4);
        const rim = pixel((m.card.left + m.card.right) / 2, m.card.top);
        await page.close();
        expect(m.border.width).toBeGreaterThan(0);
        expect(m.border.width).toBeLessThanOrEqual(1);
        expect(m.border.color).not.toMatch(/^(transparent|rgba\(0, 0, 0, 0\))$/);
        expect(distance(rim, fill)).toBeGreaterThanOrEqual(6);
        expect(m.shadow).toBe(m.elevation);
      });

      test("padding, then the title, the status row and the meta line, each a step quieter", async () => {
        const page = await open(scheme);
        const m = await page.evaluate(measure);
        await page.close();
        expect(m.title.top - m.card.top).toBeGreaterThanOrEqual(10);
        expect(m.title.left - m.card.left).toBeGreaterThanOrEqual(12);
        expect(m.meta).not.toBeNull();
        expect(m.card.bottom - m.meta!.bottom).toBeGreaterThanOrEqual(10);
        expect(m.status.top).toBeGreaterThanOrEqual(m.title.bottom);
        expect(m.meta!.top).toBeGreaterThanOrEqual(m.status.bottom);
        expect(Number(m.titleWeight)).toBeGreaterThanOrEqual(600);
        expect(m.titleSize).toBe(m.bodySize);
        expect(parseFloat(m.metaSize!)).toBeLessThan(parseFloat(m.titleSize));
        expect(m.metaColor).not.toBe(m.titleColor);
      });
    });
  }
});
