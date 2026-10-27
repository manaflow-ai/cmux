// l10n-allow-file: synthetic lane names and messages, never private transcripts.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { createHash } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import type { ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("received-message-layout-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.message-presentation";
  let vite: ViteDevServer;
  let browser: Browser;
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  const capture = async (page: Page, name: string) => {
    const directory = process.env.CMUX_TRANSCRIPT_CAPTURE_DIR;
    if (!directory) return;
    await mkdir(directory, { recursive: true });
    const bytes = await page.screenshot({ path: path.join(directory, `${name}.png`), fullPage: true });
    if (process.env.CMUX_TRANSCRIPT_EMIT_CAPTURE !== "1") return;
    const base64 = bytes.toString("base64");
    console.log(
      `TRANSCRIPT_CAPTURE_META ${JSON.stringify({ name, sha256: createHash("sha256").update(bytes).digest("hex"), bytes: bytes.length })}`,
    );
    for (let offset = 0; offset < base64.length; offset += 4096)
      console.log(`TRANSCRIPT_CAPTURE_DATA ${name} ${offset / 4096} ${base64.slice(offset, offset + 4096)}`);
  };
  const open = async (width: number, colorScheme: "dark" | "light", variant = "compact"): Promise<Page> => {
    const { port } = vite.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width, height: 760 }, colorScheme });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    if (width === 360)
      await page.evaluate(() => {
        document.documentElement.style.zoom = "1.25";
      });
    return page;
  };

  for (const colorScheme of ["dark", "light"] as const) {
    for (const width of [760, 360]) {
      test(`received and queued strips keep text clear of actions at ${width}px in ${colorScheme}`, async () => {
        const page = await open(width, colorScheme);
        const queued = page.locator("[data-queued-message]").first();
        const received = page.locator('[data-row-id="user-12"] .cv-received');
        expect(await received.locator(".cv-received__toggle").getAttribute("aria-expanded")).toBe("false");
        expect(await received.locator(".cv-received__body").count()).toBe(0);
        const strip = await received.evaluate((row) => {
          const icon = row.querySelector(".cv-received__icon")!.getBoundingClientRect();
          const sender = row.querySelector(".cv-received__name")!.getBoundingClientRect();
          const preview = row.querySelector(".cv-received__preview")!.getBoundingClientRect();
          const toggle = row.querySelector(".cv-received__toggle")!.getBoundingClientRect();
          return {
            iconCenter: icon.top + icon.height / 2,
            senderCenter: sender.top + sender.height / 2,
            previewWidth: preview.width,
            toggleWidth: toggle.width,
          };
        });
        expect(Math.abs(strip.iconCenter - strip.senderCenter)).toBeLessThanOrEqual(1);
        expect(strip.previewWidth).toBeGreaterThan(0);
        expect(strip.toggleWidth).toBeGreaterThanOrEqual(20);
        expect(await queued.locator(".cv-received__queued").textContent()).toBe("Read after this turn");
        await queued.hover();
        await page.waitForFunction(() => {
          const actions = document.querySelector("[data-queued-message] .cv-received__queued-actions");
          return actions && getComputedStyle(actions).opacity === "1";
        });
        const layout = await queued.evaluate((row) => {
          const line = row.querySelector<HTMLElement>(".cv-received__line")!;
          const status = row.querySelector<HTMLElement>(".cv-received__queued")!;
          const actions = row.querySelector<HTMLElement>(".cv-received__queued-actions")!;
          const lineBox = line.getBoundingClientRect();
          const statusBox = status.getBoundingClientRect();
          const actionsBox = actions.getBoundingClientRect();
          return {
            overlap:
              Math.max(0, Math.min(statusBox.right, actionsBox.right) - Math.max(statusBox.left, actionsBox.left)) *
              Math.max(0, Math.min(statusBox.bottom, actionsBox.bottom) - Math.max(statusBox.top, actionsBox.top)),
            overhang: actionsBox.right - lineBox.right,
            captionWidth: statusBox.width,
            actionWidth: actionsBox.width,
            actionVisibility: getComputedStyle(actions).opacity,
          };
        });
        expect(layout.overlap).toBeLessThanOrEqual(0.5);
        expect(layout.overhang).toBeLessThanOrEqual(0.5);
        expect(layout.captionWidth).toBeGreaterThan(20);
        expect(layout.actionWidth).toBeGreaterThan(30);
        expect(layout.actionVisibility).toBe("1");
        const geometry = await queued.locator(".cv-received__queued-actions").evaluate((actions) =>
          [...actions.querySelectorAll<HTMLButtonElement>("button.cv-iconbtn")].map((button) => {
            const box = button.getBoundingClientRect();
            const icon = button.querySelector("svg, [data-symbol]")!.getBoundingClientRect();
            return [box.width, box.height, icon.width, icon.height];
          }),
        );
        expect(geometry).toEqual(
          [
            [24, 24, 16, 16],
            [24, 24, 16, 16],
          ].map((sizes) => sizes.map((n) => (width === 360 ? n * 1.25 : n))),
        );
        expect(await queued.locator('button[aria-label="Copy"]').count()).toBe(1);
        expect(await queued.locator('.cv-received__queued-actions button[aria-label="Copy"]').count()).toBe(1);
        if (width === 760) await capture(page, `compact-${colorScheme}`);
        await received.locator(".cv-received__toggle").click();
        await received.locator(".cv-received__body").waitFor();
        expect(await received.locator(".cv-received__text strong").textContent()).toBe("Review passed.");
        expect(await received.locator(".cv-received__text li").count()).toBe(2);
        expect(
          await received.locator(".cv-received__body").evaluate((body) => getComputedStyle(body).backgroundColor),
        ).toBe("rgba(0, 0, 0, 0)");
        await page.close();
      });
    }
  }
  for (const colorScheme of ["dark", "light"] as const) {
    test(`mixed replay keeps one copy, explicit identity and semantic Markdown in ${colorScheme}`, async () => {
      const page = await open(760, colorScheme, "meaning-expanded");
      try {
        const received = page.locator('[data-row-id="user-12"]');
        const sender = received.locator(".cv-received__name");
        expect(await sender.locator(".acpmux-sender__name").textContent()).toContain("pr-row");
        expect(await sender.locator(".acpmux-sender__name").textContent()).not.toContain("review-host");
        expect(await sender.locator(".acpmux-sender__host").textContent()).toBe("review-host");
        expect(await sender.getAttribute("title")).toBe("Open pr-row (review-host)");
        await received.hover();
        const copy = received.getByRole("button", { name: "Copy", exact: true });
        expect(await copy.count()).toBe(1);
        await copy.hover();
        await page.waitForFunction(() => {
          const actions = document.querySelector('[data-row-id="user-12"] .cv-received-actions');
          return actions && getComputedStyle(actions).opacity === "1";
        });
        expect(
          await received
            .locator(".cv-received-actions")
            .first()
            .evaluate((node) => getComputedStyle(node).opacity),
        ).toBe("1");
        await capture(page, `copy-hover-${colorScheme}`);
        await received.getByRole("button", { name: "Pin", exact: true }).hover();
        expect(
          await received
            .locator(".cv-received-actions")
            .first()
            .evaluate((node) => getComputedStyle(node).opacity),
        ).toBe("1");
        await capture(page, `pin-hover-${colorScheme}`);
        const actionGaps = await received.locator(".cv-received__actions").evaluate((actions) => {
          const boxes = [...actions.querySelectorAll("button.cv-iconbtn")]
            .map((button) => button.getBoundingClientRect())
            .filter((box) => box.width > 0);
          return boxes.slice(1).map((box, index) => box.left - boxes[index]!.right);
        });
        for (const gap of actionGaps) expect(Math.abs(gap)).toBeLessThanOrEqual(0.5);
        await received.locator('[data-menu="queued-message"]').click();
        await page.getByRole("menuitem", { name: "Send now", exact: true }).waitFor();
        await page.mouse.move(12, 12);
        expect(
          await received
            .locator(".cv-received-actions")
            .first()
            .evaluate((node) => getComputedStyle(node).opacity),
        ).toBe("1");
        await capture(page, `step-menu-${colorScheme}`);
        await page.keyboard.press("Escape");
        expect(await page.locator('[data-row-id="presentation-shell"]').textContent()).toContain(
          "Run independent review",
        );
        const sent = page.locator('[data-row-id="presentation-send"]');
        expect(await sent.locator(".cv-md h2").textContent()).toBe("Review ready");
        expect(await sent.locator(".cv-md li").count()).toBe(2);
        expect(await sent.locator(".cv-md strong").textContent()).toBe("Queue actions");
        const queued = page.locator("[data-queued-message]").first();
        await queued.hover();
        await page.waitForFunction(() => {
          const actions = document.querySelector("[data-queued-message] .cv-received-actions");
          return actions && getComputedStyle(actions).opacity === "1";
        });
        await queued.locator('[data-menu="queued-message"]').click();
        await page.getByRole("menuitem", { name: "Edit message", exact: true }).waitFor();
        expect(await page.getByRole("menuitem", { name: "Steer", exact: true }).count()).toBe(1);
        expect(await page.getByRole("menuitem", { name: "Delete", exact: true }).count()).toBe(1);
        await page.mouse.move(12, 12);
        const visibleWhileOpen = await queued.locator(".cv-received-actions").evaluate(
          (node) =>
            new Promise<boolean>((resolve) => {
              let frames = 0;
              window.cmuxAfterPaint(() => {
                const visible = getComputedStyle(node).opacity === "1";
                if (!visible || ++frames === 16) {
                  resolve(visible);
                  return false;
                }
              });
            }),
        );
        expect(visibleWhileOpen).toBe(true);
        await capture(page, `queue-menu-${colorScheme}`);
        await page.keyboard.press("Escape");
      } finally {
        await page.close();
      }
    });
  }
});
