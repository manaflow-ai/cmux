// l10n-allow-file: gallery fixture tray labels are test data.
// The running tray tucked away behind its grabber (TrayGrabber.tsx). Leo, 2026-11-04: "Some people
// might want to tuck away the composer hat ... you can hover around that, the top of the composer, and
// then you can click that to like unleash the hat". The approved plan: three states (open, folded,
// tucked); tucked shows only a grabber on the composer's top edge, which brings the tray back folded
// (open with Option); on a showing tray the same grabber tucks it; tucked, it still says how many
// things run and draws a dot when an agent waits on the person; centre by default, left and right as
// arms. In real Chromium (Playwright; CI fails the file when it cannot launch, requireBrowserLane).
// CMUX_TRAY_CAPTURE_DIR keeps a still of each side.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-tuck.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagent-tray-tuck";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "tucked" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const open = async (variant: string, params: Record<string, string> = {}, width = 760): Promise<Page> => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({
      viewport: { width, height: 560 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, ...params })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-tray-grabber").first().waitFor({ state: "attached" });
    return page;
  };
  const state = (page: Page) =>
    page.evaluate(() => {
      const grabber = document.querySelector<HTMLElement>(".acpmux-tray-grabber");
      const head = document.querySelector(".acpmux-running-tray__head");
      return {
        tray: Boolean(document.querySelector(".acpmux-running-tray")),
        tucked: Boolean(document.querySelector(".acpmux-tray-tucked")),
        expanded: head?.getAttribute("aria-expanded") ?? null,
        label: grabber?.getAttribute("aria-label") ?? null,
        live: grabber?.hasAttribute("data-live") ?? false,
        waiting: Boolean(grabber?.querySelector(".acpmux-tray-grabber__dot")),
        count: grabber?.querySelector(".acpmux-tray-grabber__count")?.textContent ?? null,
        pill: grabber ? Number(getComputedStyle(grabber.querySelector(".acpmux-tray-grabber__pill")!).opacity) : null,
      };
    });

  test("tucked, only the grabber shows, with how many things run; a click brings the tray back folded", async () => {
    const page = await open("tucked");
    try {
      const before = await state(page);
      expect(before.tray).toBe(false);
      expect(before.tucked).toBe(true);
      expect(before.count).toBe("3");
      expect(before.live).toBe(true);
      expect(before.pill).toBe(1);
      expect(before.waiting).toBe(false);
      expect(before.label).toBe("Show running tray · 3 running");
      await page.click(".acpmux-tray-grabber");
      await page.locator(".acpmux-running-tray__head").waitFor();
      const after = await state(page);
      expect(after.tucked).toBe(false);
      expect(after.expanded).toBe("false");
    } finally {
      await page.close();
    }
  });

  test("tucked, an Option-click brings the tray back open", async () => {
    const page = await open("tucked");
    try {
      await page.click(".acpmux-tray-grabber", { modifiers: ["Alt"] });
      await page.locator(".acpmux-running-tray__head").waitFor();
      expect((await state(page)).expanded).toBe("true");
    } finally {
      await page.close();
    }
  });

  test("a showing tray's grabber is drawn only under the pointer, and its click tucks the tray", async () => {
    const page = await open("shown-hover");
    try {
      await page.mouse.move(5, 5);
      expect((await state(page)).pill).toBe(0);
      await page.hover(".acpmux-running-tray > .acpmux-tray-grabber");
      await page.waitForFunction(
        () => getComputedStyle(document.querySelector(".acpmux-tray-grabber__pill")!).opacity === "1",
      );
      expect((await state(page)).label).toBe("Tuck running tray away");
      await page.click(".acpmux-running-tray > .acpmux-tray-grabber");
      await page.locator(".acpmux-tray-tucked").waitFor({ state: "attached" });
      await page.waitForFunction(() => !document.querySelector(".acpmux-running-tray"));
    } finally {
      await page.close();
    }
  });

  test("tucked while an agent waits on the person, the grabber draws a dot and says so", async () => {
    const page = await open("tucked-waiting");
    try {
      const tucked = await state(page);
      expect(tucked.waiting).toBe(true);
      expect(tucked.label).toContain("1 waiting on you");
    } finally {
      await page.close();
    }
  });

  for (const width of [760, 360]) {
    test(`the grabber sits on the composer's top edge, centre, left or right, at ${width}px`, async () => {
      const at: Record<string, { left: number; right: number; top: number }> = {};
      let composer = { left: 0, right: 0, top: 0 };
      for (const arm of ["center", "left", "right"]) {
        const page = await open("tucked-hover", { exp: "subagent-tray-grabber", arm }, width);
        try {
          await page.hover(".acpmux-tray-grabber");
          const geometry = await page.evaluate(() => {
            const box = (node: Element) => {
              const rect = node.getBoundingClientRect();
              return { left: rect.left, right: rect.right, top: rect.top };
            };
            return {
              pill: box(document.querySelector(".acpmux-tray-grabber__pill")!),
              composer: box(document.querySelector(".acpmux-composer-box")!),
            };
          });
          at[arm] = geometry.pill;
          composer = geometry.composer;
          if (process.env.CMUX_TRAY_CAPTURE_DIR) {
            await mkdir(process.env.CMUX_TRAY_CAPTURE_DIR, { recursive: true });
            await page.screenshot({
              path: path.join(process.env.CMUX_TRAY_CAPTURE_DIR, `tray-tucked-${arm}-${width}.png`),
            });
          }
        } finally {
          await page.close();
        }
      }
      // On the composer's top edge.
      for (const pill of Object.values(at)) expect(Math.abs(pill.top - composer.top)).toBeLessThanOrEqual(1);
      const middle = (composer.left + composer.right) / 2;
      expect(Math.abs((at.center!.left + at.center!.right) / 2 - middle)).toBeLessThanOrEqual(2);
      expect(at.left!.right).toBeLessThan(middle);
      expect(at.right!.left).toBeGreaterThan(middle);
    });
  }
});
