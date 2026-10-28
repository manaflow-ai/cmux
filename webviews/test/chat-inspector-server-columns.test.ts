// Dev-server status dots keep the same leading icon column as Background task rows. This is a
// rendered geometry contract: the status mark stays seven pixels, while its slot and text start
// line up with the fourteen-pixel task icon.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-inspector-server-columns.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-inspector-server-columns: skipping (run `bunx playwright install chromium`)");
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
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.chat-inspector", {
      browser,
      params: { variant: "full", colorScheme: "light" },
    });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("server status and task command columns share their icon slot", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 420, height: 900 } });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-inspector", { variant: "full", colorScheme: "light" })}`,
    );
    await page.locator(".acpmux-chat-inspector-server__dot").first().waitFor();
    const metrics = await page
      .locator(".acpmux-chat-inspector-server")
      .first()
      .evaluate((server) => {
        const dot = server.querySelector<HTMLElement>(".acpmux-chat-inspector-server__dot")!;
        const text = server.querySelector<HTMLElement>(".acpmux-chat-inspector-server__text")!;
        const task = document.querySelector<HTMLElement>(".acpmux-chat-inspector-task__open")!;
        const icon = task.querySelector<SVGElement>(":scope > svg")!;
        const taskText = task.querySelector<HTMLElement>(".acpmux-chat-inspector-task__command")!;
        const dotBox = dot.getBoundingClientRect();
        const iconBox = icon.getBoundingClientRect();
        return {
          dotWidth: dotBox.width,
          dotCenter: dotBox.left + dotBox.width / 2,
          iconCenter: iconBox.left + iconBox.width / 2,
          serverText: text.getBoundingClientRect().left,
          taskText: taskText.getBoundingClientRect().left,
        };
      });
    expect(metrics.dotWidth).toBe(7);
    expect(Math.abs(metrics.dotCenter - metrics.iconCenter)).toBeLessThanOrEqual(0.5);
    expect(Math.abs(metrics.serverText - metrics.taskText)).toBeLessThanOrEqual(0.5);
    await page.close();
  });

  test("cards reorder when dragged from the visible grip", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 420, height: 900 } });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-inspector", { variant: "cards-balanced", colorScheme: "light" })}`,
    );
    const handle = page.locator('[data-section-card="changes"] .acpmux-chat-inspector-card__handle');
    const target = page.locator('[data-section-card="context"]');
    await handle.waitFor();
    expect(
      await handle.evaluate((node) => {
        const box = node.getBoundingClientRect();
        return (
          document
            .elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)
            ?.closest(".acpmux-chat-inspector-card__handle") === node
        );
      }),
    ).toBe(true);
    await handle.dragTo(target);
    const order = await page
      .locator("[data-section-card]")
      .evaluateAll((cards) => cards.map((card) => card.getAttribute("data-section-card")));
    expect(order.indexOf("changes")).toBeLessThan(order.indexOf("context"));
    await page.close();
  });

  test("sticky card headers reveal the edge only after scrolling, and not when folded", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 420, height: 900 } });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-inspector", { variant: "cards-balanced", colorScheme: "light" })}`,
    );
    const section = page.locator('section[data-section="outputs"]');
    await section.waitFor();
    await section.evaluate((node) => {
      const list = node.querySelector<HTMLElement>(".acpmux-chat-inspector-scroll")!;
      const first = list.querySelector("li")!;
      for (let index = 0; index < 24; index++) list.append(first.cloneNode(true));
    });
    await page.waitForFunction(
      (node) => (node as HTMLElement).scrollHeight > (node as HTMLElement).clientHeight,
      await section.elementHandle(),
    );
    const scrollable = await section.evaluate((node) => {
      const section = node as HTMLElement;
      return { scrollHeight: section.scrollHeight, clientHeight: section.clientHeight };
    });
    expect(scrollable.scrollHeight).toBeGreaterThan(scrollable.clientHeight);
    const edge = section.locator(".ui-scroll-edge-fade");
    expect(await edge.evaluate((node) => getComputedStyle(node, "::after").opacity)).toBe("0");
    if (process.env.CMUX_CAPTURE_DIR) {
      await page.screenshot({ path: path.join(process.env.CMUX_CAPTURE_DIR, "session-info-scroll-0.png") });
    }
    await section.evaluate((node) => {
      const section = node as HTMLElement;
      section.scrollTop = section.scrollHeight;
      section.dispatchEvent(new Event("scroll"));
    });
    await page.waitForFunction(
      (node) => getComputedStyle(node as Element, "::after").opacity === "1",
      await edge.elementHandle(),
    );
    // The disclosure's reset/hover styles must not make the sticky header transparent.
    for (const hovered of [false, true]) {
      if (hovered) await edge.hover();
      expect(
        await edge.evaluate((node) => {
          const canvas = document.createElement("canvas");
          const context = canvas.getContext("2d")!;
          context.fillStyle = getComputedStyle(node).backgroundColor;
          context.fillRect(0, 0, 1, 1);
          return context.getImageData(0, 0, 1, 1).data[3];
        }),
      ).toBe(255);
    }

    if (process.env.CMUX_CAPTURE_DIR) {
      await page.screenshot({ path: path.join(process.env.CMUX_CAPTURE_DIR, "session-info-scroll-scrolled.png") });
    }
    await section.locator(".ui-disclosure-trigger").click();
    await page.waitForFunction(
      (node) => getComputedStyle(node as Element, "::after").opacity === "0",
      await edge.elementHandle(),
    );
    await page.close();
  });

  test("linked and plain Sources share the same icon gap", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 420, height: 900 } });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-inspector", { variant: "cards-balanced", colorScheme: "light" })}`,
    );
    const sources = page.locator(".acpmux-chat-inspector-source");
    await sources.first().waitFor();
    const gaps = await sources.evaluateAll((rows) =>
      rows.map((row) => {
        const label = row.querySelector(".acpmux-chat-inspector-source__label")!;
        const icon = row.querySelector("svg")!;
        return label.getBoundingClientRect().left - icon.getBoundingClientRect().right;
      }),
    );
    expect(gaps.length).toBeGreaterThan(2);
    for (const gap of gaps) expect(gap).toBeCloseTo(8);
    await page.close();
  });

  test("Session Info wave variants use their declared durations", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (const [variant, duration] of [
      ["wave-subtle", "2s"],
      ["wave-balanced", "2.4s"],
      ["wave-roomy", "3s"],
    ] as const) {
      const page = await browser!.newPage({ viewport: { width: 420, height: 900 } });
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-inspector", { variant, colorScheme: "light" })}`,
      );
      await page.locator(".acpmux-chat-inspector-task__wave.acpmux-wave-item").first().waitFor();
      expect(
        await page
          .locator(".acpmux-chat-inspector-task__wave.acpmux-wave-item")
          .first()
          .evaluate((node) => getComputedStyle(node).animationDuration),
      ).toBe(duration);
      await page.close();
    }
  });
});
