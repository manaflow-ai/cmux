// Leo, 2026-10-24: "we ought to be able to drag and reorder images if we're seeing the non-inline
// attachment composer". A staged chip dragged along the strip moves there (composer/stripReorder.ts),
// and the prompt sends its attachments in the strip's order; Option-Left/Right move a focused chip.
// The page is the pane's dev entry with the in-page mock transport.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-attach-reorder.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-attach-reorder: skipping (run `bunx playwright install chromium`)");
    describe.skip("reordering attachments", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function newChat(colorScheme: "light" | "dark" = "light"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 }, colorScheme });
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            agentSession: { postMessage: async () => ({ ok: true, value: null }) },
          },
        },
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }),
        },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    // Reordering is a feature of the attachment strip (the non-inline view), so the strip is on.
    await page.evaluate(() => window.cmuxAcpmuxComposer?.({ attachmentView: "strip" }));
    return page;
  }

  /// Pastes three PNGs 300, 400 and 500 px wide, as one ⌘V of copied images.
  const pasteThree = (page: Page) =>
    page.evaluate(async () => {
      const data = new DataTransfer();
      for (const width of [300, 400, 500]) {
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = 200;
        const context = canvas.getContext("2d")!;
        context.fillStyle = `hsl(${width}, 60%, 50%)`;
        context.fillRect(0, 0, width, 200);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
        data.items.add(new File([blob], `Shot ${width}.png`, { type: "image/png" }));
      }
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable='true']")!;
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });

  /// The staged images' widths, in the strip's order (each chip is named for its width).
  const order = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll<HTMLImageElement>(".acpmux-attachments .acpmux-attachment-image img")].map(
        (img) => /Shot (\d+)/.exec(img.alt)?.[1] ?? img.alt,
      ),
    );

  async function staged(page: Page) {
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await pasteThree(page);
    await page.waitForFunction(() => {
      const images = [
        ...document.querySelectorAll<HTMLImageElement>(".acpmux-attachments .acpmux-attachment-image img"),
      ];
      return images.length === 3 && images.every((img) => img.complete && img.naturalWidth > 0);
    });
    expect(await order(page)).toEqual(["300", "400", "500"]);
  }

  // Leo, 2026-10-24: "we ought to be able to drag and reorder images if we're seeing the non-inline
  // attachment composer".
  test("dragging a chip past another moves it, and the drag opens nothing", async () => {
    const page = await newChat();
    await staged(page);
    const chips = page.locator(".acpmux-attachments .acpmux-attachment-image");
    const first = (await chips.nth(0).boundingBox())!;
    const last = (await chips.nth(2).boundingBox())!;
    await page.mouse.move(first.x + first.width / 2, first.y + first.height / 2);
    await page.mouse.down();
    await page.mouse.move(first.x + first.width / 2 + 10, first.y + first.height / 2, { steps: 3 });
    await page.mouse.move(last.x + last.width - 4, last.y + last.height / 2, { steps: 12 });
    // The chip being dragged lifts.
    expect(
      await page
        .locator(".acpmux-attachments .acpmux-attachment-slot[data-dragging] .acpmux-attachment")
        .evaluate((chip) => getComputedStyle(chip).transform),
    ).not.toBe("none");
    // Leo, 2026-10-26: "there's no click-and-drag animation or whatever. Like, it has to just look
    // like a drag-and-drop". The chip rides the pointer: grabbed at its center, it is still centered
    // under the pointer (clamped inside the strip), not parked in its new slot.
    const pointerX = last.x + last.width - 4;
    const ride = await page.evaluate(() => {
      const strip = document.querySelector(".acpmux-attachments")!.getBoundingClientRect();
      const chip = document
        .querySelector(".acpmux-attachments .acpmux-attachment-slot[data-dragging] .acpmux-attachment")!
        .getBoundingClientRect();
      return { center: chip.left + chip.width / 2, right: chip.right, stripRight: strip.right };
    });
    expect(Math.abs(ride.center - pointerX) < 2 || Math.abs(ride.right - ride.stripRight) < 2).toBe(true);
    // The chips it passed slide to their new slots instead of jumping there.
    expect(
      await page.evaluate(
        () =>
          [
            ...document.querySelectorAll(
              ".acpmux-attachments .acpmux-attachment-slot:not([data-dragging]) .acpmux-attachment",
            ),
          ].flatMap((chip) => chip.getAnimations()).length,
      ),
    ).toBeGreaterThan(0);
    await page.mouse.up();
    expect(await order(page)).toEqual(["400", "500", "300"]);
    // Released, it settles into its slot and keeps no offset of its own.
    await page.waitForFunction(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-attachments .acpmux-attachment")].every(
        (chip) => chip.style.translate === "" && chip.getAnimations().length === 0,
      ),
    );
    expect(await page.locator(".acpmux-attachments .acpmux-attachment-slot[data-dragging]").count()).toBe(0);
    // Assistive technology hears where it went, while the announcement stays out of the
    // visual strip. Leo, 2026-10-26: the movement hint and status must not be visible UI.
    const announcement = page.locator(".acpmux-attachments output[aria-live]");
    expect(await announcement.textContent()).toBe("Shot 300.png moved to 3 of 3");
    const accessibilityStyle = await announcement.evaluate((element) => {
      const style = getComputedStyle(element);
      return { className: element.className, clipPath: style.clipPath, position: style.position };
    });
    expect(accessibilityStyle.className).toContain("acpmux-attachment-voiceover-only");
    expect(accessibilityStyle.clipPath).toBe("inset(50%)");
    expect(accessibilityStyle.position).toBe("absolute");
    // The press that ended the drag opened no viewer.
    expect(await page.locator(".acpmux-image-viewer, [role=dialog]").count()).toBe(0);
    await page.close();
  });

  test("Option-Left and Option-Right move the focused chip", async () => {
    const page = await newChat();
    await staged(page);
    await page.locator(".acpmux-attachments .acpmux-attachment-image .acpmux-attachment-open").nth(0).focus();
    await page.keyboard.press("Alt+ArrowRight");
    expect(await order(page)).toEqual(["400", "300", "500"]);
    await page.keyboard.press("Alt+ArrowRight");
    expect(await order(page)).toEqual(["400", "500", "300"]);
    await page.keyboard.press("Alt+ArrowLeft");
    expect(await order(page)).toEqual(["400", "300", "500"]);
    await page.close();
  });

  test("right to left, Option-Left moves a chip later in the strip, as it looks", async () => {
    const page = await newChat();
    await page.evaluate(() => document.documentElement.setAttribute("dir", "rtl"));
    await staged(page);
    await page.locator(".acpmux-attachments .acpmux-attachment-image .acpmux-attachment-open").nth(0).focus();
    await page.keyboard.press("Alt+ArrowLeft");
    expect(await order(page)).toEqual(["400", "300", "500"]);
    await page.keyboard.press("Alt+ArrowRight");
    expect(await order(page)).toEqual(["300", "400", "500"]);
    await page.close();
  });

  test("a strip of chips wider than the composer marks the side it scrolls to", async () => {
    const page = await newChat();
    await page.setViewportSize({ width: 420, height: 640 });
    await staged(page);
    // The chips' images decoded after the strip mounted: its fade still says there is more.
    await page.waitForFunction(() => document.querySelector(".acpmux-attachments")?.hasAttribute("data-fade-right"));
    await page.close();
  });

  test("a plain click on a chip still opens it", async () => {
    const page = await newChat();
    await staged(page);
    await page.locator(".acpmux-attachments .acpmux-attachment-image .acpmux-attachment-open").nth(1).click();
    await page.locator("[role=dialog]").first().waitFor();
    expect(await order(page)).toEqual(["300", "400", "500"]);
    await page.close();
  });
});
