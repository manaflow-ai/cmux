// l10n-allow-file: synthetic gallery messages.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("message-preview-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.message-preview";
  let vite: ViteDevServer;
  let browser: Browser;
  let page: Page;
  beforeAll(async () => {
    const { createServer } = await import("vite");
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser });
    page = await browser.newPage({ viewport: { width: 700, height: 1000 } });
    page.setDefaultTimeout(5_000);
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  const open = async (variant = "cards-no-fade") => {
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
  };
  /// The received messages' toggles: each message is its own disclosure line (IncomingMessageCard.tsx).
  const toggle = () => page.locator(".cv-received .cv-disclosure__toggle");
  /// Resolves once nothing in the first received message is moving.
  const folded = () =>
    page
      .locator(".cv-received")
      .first()
      .evaluate((row) =>
        Promise.all(row.getAnimations({ subtree: true }).map((animation) => animation.finished.catch(() => undefined))),
      );
  // Check actual rendered glyph and chip boxes, not an assumed line-height grid.
  const intact = (selector: string) =>
    page.locator(selector).evaluate((box) => {
      const edge = box.getBoundingClientRect().bottom;
      const rects: DOMRect[] = [];
      const walker = document.createTreeWalker(box, NodeFilter.SHOW_TEXT);
      const range = document.createRange();
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (!node.nodeValue?.trim()) continue;
        range.selectNodeContents(node);
        rects.push(...range.getClientRects());
      }
      for (const atom of box.querySelectorAll("code, .cv-chip")) rects.push(...atom.getClientRects());
      return {
        mask: getComputedStyle(box).maskImage,
        split: rects.filter((r) => r.top < edge - 0.1 && r.bottom > edge + 0.1).length,
        visible: rects.some((r) => r.bottom <= edge),
      };
    });
  test("a received message is one ellipsized line at wide and narrow zoomed widths, and opens whole", async () => {
    await open();
    expect(await page.locator(".cv-received").count()).toBe(2);
    for (const width of [700, 360]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(
        (zoom) => {
          document.documentElement.style.zoom = String(zoom);
        },
        width === 360 ? 1.25 : 1,
      );
      // Closed: the line alone, its first line cut with an ellipsis on one line, nothing under it.
      expect(await page.locator(".cv-received__text, .cv-received__show, [data-cut]").count()).toBe(0);
      const preview = await page
        .locator(".cv-received__preview")
        .first()
        .evaluate((box) => {
          const style = getComputedStyle(box);
          return {
            overflow: style.textOverflow,
            wrap: style.whiteSpace,
            // One line: no taller than the 26px line it sits on.
            oneLine:
              box.getBoundingClientRect().height <=
              box.closest(".cv-disclosure__line")!.getBoundingClientRect().height + 0.5,
          };
        });
      expect(preview).toEqual({ overflow: "ellipsis", wrap: "nowrap", oneLine: true });
    }
    await page.setViewportSize({ width: 700, height: 1000 });
    await page.evaluate(() => {
      document.documentElement.style.zoom = "1";
    });
    await toggle().first().focus();
    await page.keyboard.press("Enter");
    expect(await toggle().first().getAttribute("aria-expanded")).toBe("true");
    await folded();
    // All of it shows: no mask, no line split by an edge, nothing scrolled away inside the box.
    expect(await intact(".cv-received__text >> nth=0")).toEqual({ mask: "none", split: 0, visible: true });
    expect(
      await page
        .locator(".cv-received__text")
        .first()
        .evaluate((box) => box.clientHeight >= box.scrollHeight && box.textContent!.includes("Step 12")),
    ).toBe(true);
    await toggle().first().click();
    await page.locator(".cv-received__text").first().waitFor({ state: "detached" });
  });
  test("sent preview has no fade or partial chip and Show more reveals all of it", async () => {
    await open();
    await page.locator(".cv-message .cv-agentmsg__toggle").click();
    await page.locator(".cv-message__text").waitFor();
    expect((await intact(".cv-message__text")).mask).toBe("none");
    await page.locator(".cv-message__more").waitFor();
    expect(await intact(".cv-message__text")).toEqual({ mask: "none", split: 0, visible: true });
    await page.locator(".cv-message__more").click();
    expect(await page.locator(".cv-message__text").evaluate((box) => box.clientHeight >= box.scrollHeight)).toBe(true);
    await page.locator(".cv-message .cv-agentmsg__toggle").click();
    await page.locator(".cv-message .cv-agentmsg__toggle").click();
    expect(await page.locator(".cv-message__more").getAttribute("aria-expanded")).toBe("true");
    await page.locator(".cv-message__more").press("Enter");
    expect(await intact(".cv-message__text")).toEqual({ mask: "none", split: 0, visible: true });
  });
  test("Minimal Mode draws the same one line, which opens the whole message", async () => {
    await open("one-line");
    expect(await page.locator(".cv-received__text").count()).toBe(0);
    expect(
      await page
        .locator(".cv-received__preview")
        .first()
        .evaluate((box) => getComputedStyle(box).textOverflow),
    ).toBe("ellipsis");
    await toggle().first().click();
    await page.locator(".cv-received__text").waitFor();
    await folded();
    expect(await intact(".cv-received__text")).toEqual({ mask: "none", split: 0, visible: true });
  });
  for (const direction of ["received", "sent"] as const) {
    test(`Tab reaches ${direction} code controls inside the shown text`, async () => {
      await open("code-first");
      const row = page.locator(direction === "received" ? ".cv-received" : ".cv-message");
      const toggle = row.locator(direction === "received" ? ".cv-disclosure__toggle" : ".cv-agentmsg__toggle");
      const text = row.locator(direction === "received" ? ".cv-received__text" : ".cv-message__text");
      if (direction === "sent") {
        await toggle.click();
        await row.locator(".cv-codeblock button").first().waitFor({ state: "attached" });
        await page.waitForFunction(
          (selector) => document.querySelector<HTMLElement>(selector)?.style.maxHeight === "0px",
          ".cv-message__text",
        );
      } else {
        // A received message's code is in its panel, which the line's toggle opens whole.
        expect(await row.locator(".cv-codeblock").count()).toBe(0);
        await toggle.focus();
        await page.keyboard.press("Enter");
        await row.locator(".cv-codeblock button").first().waitFor({ state: "attached" });
        await folded();
      }
      await toggle.focus();
      let reached = false;
      for (let step = 0; step < 12; step++) {
        await page.keyboard.press("Tab");
        reached = await text.evaluate((box) => box.contains(document.activeElement));
        if (reached) break;
      }
      expect(reached).toBe(true);
      expect(
        await text.evaluate((box) => {
          const control = document.activeElement!.getBoundingClientRect();
          const clip = box.getBoundingClientRect();
          return control.top >= clip.top && control.bottom <= clip.bottom;
        }),
      ).toBe(true);
      expect(await text.evaluate((box) => box.style.maxHeight)).toBe("");
    });
  }
});
