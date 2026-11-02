// The page blurs itself under a floating glass in a see-through Chromium page (src/ui/glass/
// seeThroughBlur.ts, glass.css "THE PAGE BLURS ITSELF UNDER THE GLASS"; Leo 2026-10-30, on the
// Summary popover: "I don't like the non-glassness"). Chromium draws a backdrop's blurred copy over
// the page's own pixels, so over a clear page the text under the popover stayed sharp and read
// through its tint. The page here is clear, as the app's see-through Chromium page is (the
// screenshot omits the background), with white bars standing in for the chat's text.
//
// Before: the bars under the popover keep their full contrast. After: inside the popover's rounded
// rect they are blurred to an even veil, outside it they are as sharp as before, and the popover
// draws no underlay. WebKit, whose backdrop already draws in place, gets nothing.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { backdropBlurRadius, drawsBackdropOver, holeIn, holeMask } from "../src/ui/glass/seeThroughBlur";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("see-through-blur.test.ts", async () => {
  setDefaultTimeout(120_000);

  /** A DOMRect for the geometry tests (bun has no DOM). */
  class DOMRectReadOnlyLike {
    readonly left: number;
    readonly top: number;
    readonly right: number;
    readonly bottom: number;
    readonly x: number;
    readonly y: number;
    constructor(
      x: number,
      y: number,
      readonly width: number,
      readonly height: number,
    ) {
      this.x = this.left = x;
      this.y = this.top = y;
      this.right = x + width;
      this.bottom = y + height;
    }
    toJSON() {
      return this;
    }
  }

  describe("see-through blur geometry", () => {
    test("reads the blur radius from a backdrop-filter value", () => {
      expect(backdropBlurRadius("blur(24px) saturate(1.8)")).toBe(24);
      expect(backdropBlurRadius("saturate(1.8) blur(12.5px)")).toBe(12.5);
      expect(backdropBlurRadius("none")).toBe(24);
      expect(backdropBlurRadius("none", 8)).toBe(8);
    });

    test("puts the hole in the covered element's own box, its corner no larger than the hole", () => {
      const surface = new DOMRectReadOnlyLike(300, 60, 200, 100);
      const target = new DOMRectReadOnlyLike(20, 10, 600, 400);
      expect(holeIn(surface, target, { radius: 80, blur: 24 })).toEqual({
        x: 280,
        y: 50,
        width: 200,
        height: 100,
        radius: 50,
        blur: 24,
      });
    });

    test("a window with no CSS.supports (a test DOM) is not taken for Chromium", () => {
      expect(drawsBackdropOver({} as Window)).toBe(false);
    });

    test("the mask is a rounded rect of the hole's own size", () => {
      const svg = decodeURIComponent(holeMask(200.4, 99.6, 12).replace("data:image/svg+xml,", ""));
      expect(svg).toContain('width="200" height="100"');
      expect(svg).toContain('rx="12" ry="12"');
    });
  });

  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "ui/glass/glass.css", "agent-session/acpmux/summary/summary.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n");
  const entry = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "see-through-blur-")), "entry.ts");
  fs.writeFileSync(
    entry,
    `import { attachSeeThroughBlur } from ${JSON.stringify(path.join(source, "ui/glass/seeThroughBlur.ts"))};
     Object.assign(window, { attachSeeThroughBlur });`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0]!.text();
  fs.rmSync(path.dirname(entry), { recursive: true, force: true });

  // The stage: a scrolled "chat" of white bars (2 px every 8 px), offset in the stage so the hole
  // is in its own box, and the popover 240 x 100 over its right half. The popover's own tint, rim
  // and backdrop are cleared so the pixels under it are the page's alone.
  const POPOVER = { x: 220, y: 40, width: 240, height: 100 };
  const html = () =>
    `<!doctype html><html data-cmux-see-through data-glass="plain"
       style="--cmux-surface-background:transparent;--cmux-surface-solid:rgb(30,30,30);background:transparent">
     <head><style>${css}
       body { margin: 0; background: transparent }
       .stage { position: relative; width: 480px; height: 180px }
       .chat { position: absolute; left: 12px; top: 6px; width: 460px; height: 170px; overflow: auto }
       .bars { height: 600px; background: repeating-linear-gradient(90deg, #fff 0 2px, transparent 2px 8px) }
       .popover { position: absolute; left: ${POPOVER.x}px; top: ${POPOVER.y}px; width: ${POPOVER.width}px;
         height: ${POPOVER.height}px; border-radius: 12px; --glass-surface: transparent;
         --glass-backdrop: blur(24px); --glass-rim-shadow: 0 0 transparent; --glass-elevation: 0 0 transparent;
         backdrop-filter: none !important }
     </style></head><body><div class="stage">
       <div class="chat"><div class="bars"></div></div>
       <aside class="popover ui-glass ui-glass-floats" id="popover"></aside>
     </div><script>${script}</script></body></html>`;

  async function open(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 480, height: 180 }, deviceScaleFactor: 1 });
    await page.setContent(html());
    await page.evaluate(() => {
      document.querySelector(".chat")!.scrollTop = 37;
    });
    return page;
  }

  /** A few frames: what the follow loop needs to see a change (it measures in the next frame). */
  async function settle(page: Page): Promise<void> {
    await page.evaluate(
      () =>
        new Promise((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        ),
    );
  }

  /** Attaches to the popover; `owner` tags what it covers, `dock` keeps its underlay over .dock. */
  async function attach(page: Page, options: { owner?: string; dock?: boolean } = {}): Promise<void> {
    await page.evaluate(({ owner, dock }) => {
      const target = window as unknown as {
        attachSeeThroughBlur(
          e: HTMLElement,
          candidates?: (e: HTMLElement) => Iterable<Element>,
          options?: { owner?: string; keepUnderlayOver?: () => Iterable<Element> },
        ): () => void;
        detach?: () => void;
      };
      const popover = document.getElementById("popover")!;
      // The dock is never a candidate (as the composer is not): only keepUnderlayOver sees it.
      const candidates = (e: HTMLElement) =>
        Array.from(e.parentElement!.children).filter((child) => !child.classList.contains("dock"));
      target.detach = target.attachSeeThroughBlur(popover, candidates, {
        owner,
        keepUnderlayOver: dock ? () => document.querySelectorAll(".dock") : undefined,
      });
    }, options);
    // The follow loop settles within a few frames.
    await page.evaluate(
      () =>
        new Promise((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        ),
    );
  }

  /** The mean luminance gap between a bar column and the gap 4 px on, along row `y` from `x0` to
   * `x1`, with the clear page laid over mid grey (the window). */
  async function barContrast(page: Page, y: number, x0: number, x1: number): Promise<number> {
    const png = PNG.sync.read(await page.screenshot({ omitBackground: true }));
    const at = (x: number) => {
      const i = (y * png.width + x) * 4;
      const alpha = png.data[i + 3]! / 255;
      const channel = (c: number) => png.data[i + c]! * alpha + 128 * (1 - alpha);
      return 0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2);
    };
    let sum = 0;
    let count = 0;
    // The bars start at the chat's left edge (x = 12): a bar's first column is at x % 8 == 4.
    for (let x = x0 - ((x0 - 4) % 8) + 8; x + 4 < x1; x += 8) {
      sum += Math.abs(at(x) - at(x + 4));
      count++;
    }
    return sum / count;
  }

  const MIDDLE = POPOVER.y + POPOVER.height / 2;
  const INSIDE = [POPOVER.x + 24, POPOVER.x + POPOVER.width - 24] as const;
  const OUTSIDE = [20, POPOVER.x - 24] as const;

  describe("see-through blur in chromium", () => {
    let browser: Browser;
    beforeAll(async () => {
      browser = await chromium.launch({ headless: true });
    });
    afterAll(async () => browser?.close());

    test("the bars under the popover blur in place; the rest stay sharp; detach restores them", async () => {
      const page = await open(browser);
      const before = await barContrast(page, MIDDLE, ...INSIDE);
      const outsideBefore = await barContrast(page, MIDDLE, ...OUTSIDE);
      await attach(page);
      const after = await barContrast(page, MIDDLE, ...INSIDE);
      const outsideAfter = await barContrast(page, MIDDLE, ...OUTSIDE);
      expect(before).toBeGreaterThan(40);
      expect(after).toBeLessThan(before * 0.08);
      expect(Math.abs(outsideAfter - outsideBefore)).toBeLessThan(2);
      expect(await page.evaluate(() => document.querySelector(".chat")!.hasAttribute("data-glass-under"))).toBe(true);
      expect(await page.evaluate(() => document.getElementById("popover")!.hasAttribute("data-glass-over"))).toBe(true);
      await page.evaluate(() => (window as unknown as { detach(): void }).detach());
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      expect(await barContrast(page, MIDDLE, ...INSIDE)).toBeGreaterThan(before * 0.95);
      expect(await page.evaluate(() => document.querySelectorAll("[data-glass-under], svg filter").length)).toBe(0);
      await page.close();
    });

    // No in-between blur (Leo, 2026-10-26: "If we're doing blur, we're doing blur. If we're not
    // doing blur, we're not doing blur. We shouldn't have in-between states ever. That cause
    // flicker"). A popover caught mid-fade blurred the bars only part way, mixing them with their
    // sharp selves by its opacity: they are blurred in full while it shows at all, sharp once it is
    // gone.
    test("a popover mid-fade blurs the bars in full, never part way", async () => {
      const page = await open(browser);
      const before = await barContrast(page, MIDDLE, ...INSIDE);
      await page.evaluate(() => (document.getElementById("popover")!.style.opacity = "0.3"));
      await attach(page);
      expect(await barContrast(page, MIDDLE, ...INSIDE)).toBeLessThan(before * 0.08);
      await page.evaluate(() => (document.getElementById("popover")!.style.opacity = "0"));
      await page.evaluate(() => document.getElementById("popover")!.dispatchEvent(new Event("transitionrun")));
      await settle(page);
      expect(await barContrast(page, MIDDLE, ...INSIDE)).toBeGreaterThan(before * 0.95);
      await page.close();
    });

    test("the popover over a page that blurs itself draws no underlay", async () => {
      const page = await open(browser);
      const underlay = () =>
        page.evaluate(() =>
          getComputedStyle(document.getElementById("popover")!).getPropertyValue("--glass-underlay").trim(),
        );
      expect(await underlay()).toBe("70%");
      await attach(page);
      expect(await underlay()).toBe("0%");
      await page.close();
    });

    test("an opaque window's page keeps its backdrop: no filter applies", async () => {
      const page = await open(browser);
      await page.evaluate(() => document.documentElement.removeAttribute("data-cmux-see-through"));
      await attach(page);
      expect(await page.evaluate(() => getComputedStyle(document.querySelector(".chat")!).filter)).toBe("none");
      await page.close();
    });
  });

  describe("see-through blur around the chat's own rules", () => {
    let browser: Browser;
    beforeAll(async () => {
      browser = await chromium.launch({ headless: true });
    });
    afterAll(async () => browser?.close());

    test("the Summary's blocks lose their filter under summary.css's hide rule, even for a Find bar deep inside, and get it back", async () => {
      const page = await open(browser);
      await page.evaluate(() => document.querySelector(".stage")!.classList.add("acpmux-stage"));
      await attach(page, { owner: "summary" });
      const filter = () => page.evaluate(() => getComputedStyle(document.querySelector(".chat")!).filter);
      expect(await page.evaluate(() => document.querySelector(".chat")!.getAttribute("data-glass-under"))).toBe(
        "summary",
      );
      expect(await filter()).toContain("url(");
      // Find opens inside the scroller: no change to the stage's own children.
      await page.evaluate(() => {
        const find = document.createElement("div");
        find.className = "acpmux-find";
        document.querySelector(".bars")!.append(find);
      });
      expect(await filter()).toBe("none");
      // Find closes: the blur is back at once, with no event the follow loop would see.
      await page.evaluate(() => document.querySelector(".acpmux-find")!.remove());
      expect(await filter()).toContain("url(");
      expect(await barContrast(page, MIDDLE, ...INSIDE)).toBeLessThan(5);
      await page.close();
    });

    test("over the composer (which takes no filter) the surface keeps its underlay", async () => {
      const page = await open(browser);
      const underlay = () =>
        page.evaluate(() =>
          getComputedStyle(document.getElementById("popover")!).getPropertyValue("--glass-underlay").trim(),
        );
      await page.evaluate(() => {
        const dock = document.createElement("div");
        dock.className = "dock";
        dock.style.cssText = "position:absolute;left:0;right:0;bottom:0;height:20px";
        document.querySelector(".stage")!.append(dock);
      });
      await attach(page, { dock: true });
      // The dock at the bottom misses the popover: the page blurs itself and the underlay goes.
      expect(await underlay()).toBe("0%");
      await page.evaluate(() => {
        (document.querySelector(".dock") as HTMLElement).style.height = "60px";
      });
      await settle(page);
      expect(await underlay()).toBe("70%");
      await page.close();
    });
  });

  describe("see-through blur in webkit", () => {
    let browser: Browser;
    beforeAll(async () => {
      browser = await webkit.launch({ headless: true });
    });
    afterAll(async () => browser?.close());

    test("WebKit's backdrop already draws in place: nothing is attached", async () => {
      const page = await open(browser);
      await attach(page);
      expect(await page.evaluate(() => document.querySelectorAll("[data-glass-under], [data-glass-over]").length)).toBe(
        0,
      );
      await page.close();
    });
  });
});
