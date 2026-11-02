// cmux-web-test-timeout: 300
// Leo 2026-10-25: "fix the basics first". The compact model menu listed the agent CLI's update as
// its last row, among the model choices and inside the list's held height. It is maintenance, so
// it sits in a quiet footer below the choices, on the rail menu and on a started chat's menu with
// no rail, and the keyboard still reaches its Update and closes the menu with it.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it
// cannot launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/model-menu-update-footer.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("model-menu-update-footer.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`model menu update footer: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("model menu update footer", () => test("browsers", () => {}));
    return;
  }

  const ENTRY = "agent-pane.model-picker";
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stage = { frame: "component", width: "normal", theme: "Apple System Colors" };
  const port = () => (vite!.httpServer!.address() as { port: number }).port;
  const stageURL = (variant: string, height: number) =>
    `http://127.0.0.1:${port()}${galleryFrame(ENTRY, { ...stage, variant, height })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, {
      browser: [...browsers.values()][0],
      params: { variant: "quick-update-offer" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** Every finite animation done, then two painted frames: what the window shows at rest. */
  const atRest = (page: Page) =>
    page.evaluate(async () => {
      const finite = () =>
        document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      for (let moving = finite(); moving.length > 0; moving = finite())
        await Promise.allSettled(moving.map((animation) => animation.finished));
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });

  /** The variant's stage in a window `height` tall, its compact menu open (the gallery play opens it). */
  const open = async (engine: string, variant: string, height = 520): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height } });
    await page.goto(stageURL(variant, height));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await installPaintedFrames(page);
    await page.locator(".acpmux-quick-menu").waitFor();
    await atRest(page);
    return page;
  };

  const layout = (page: Page) =>
    page.evaluate(() => {
      const popup = document.querySelector<HTMLElement>(".acpmux-quick-menu")!;
      const footer = popup.querySelector<HTMLElement>(".acpmux-quick-update");
      const box = (element: Element) => {
        const rect = element.getBoundingClientRect();
        return { top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right };
      };
      const rows = [...popup.querySelectorAll('[role^="menuitem"]')].filter((row) => !footer?.contains(row));
      // The rail menu's list scrolls in its own box, which ends where the footer starts; the plain
      // menu scrolls rows and footer together, so its rows end above the footer at any scroll.
      const layout = popup.querySelector(".acpmux-quick-layout");
      return {
        popup: box(popup),
        footer: footer ? box(footer) : undefined,
        inList: !!footer?.closest(".acpmux-quick-list"),
        lastChild: popup.lastElementChild === footer,
        listBottom: layout
          ? layout.getBoundingClientRect().bottom
          : Math.max(...rows.map((row) => row.getBoundingClientRect().bottom)),
        rowWithUpdate: rows.some((row) => row.textContent?.includes("2.2.0")),
        actions: footer ? [...footer.querySelectorAll('[role^="menuitem"]')].map((item) => item.textContent) : [],
      };
    });

  /** ArrowDown until the keyboard is on the footer's Update; whether it got there. */
  const toUpdate = async (page: Page) => {
    for (let step = 0; step < 24; step++) {
      await page.keyboard.press("ArrowDown");
      if (await page.evaluate(() => document.activeElement?.closest(".acpmux-quick-update") !== null)) return true;
    }
    return false;
  };

  for (const [engine] of engines) {
    for (const variant of ["quick-update-offer", "started-chat-update-offer"]) {
      test(`${engine} ${variant}: the update is a footer below the model choices`, async () => {
        const page = await open(engine, variant);
        const boxes = await layout(page);
        console.log(`::notice title=model-menu-update-footer (${engine} ${variant})::${JSON.stringify(boxes)}`);
        expect(boxes.footer, "a footer holds the update").toBeDefined();
        expect(boxes.inList, "the footer is outside the model list").toBe(false);
        expect(boxes.lastChild, "the footer is the popup's last child").toBe(true);
        expect(boxes.rowWithUpdate, "no model row carries the update").toBe(false);
        expect(boxes.actions).toEqual(["Update"]);
        expect(boxes.footer!.top, "below the choices").toBeGreaterThanOrEqual(boxes.listBottom - 1);
        expect(boxes.footer!.bottom, "inside the popup").toBeLessThanOrEqual(boxes.popup.bottom + 1);
        expect(boxes.footer!.left).toBeGreaterThanOrEqual(boxes.popup.left - 1);
        expect(boxes.footer!.right).toBeLessThanOrEqual(boxes.popup.right + 1);
        await page.close();
      });

      test(`${engine} ${variant}: the keyboard reaches Update, and Enter on it closes the menu`, async () => {
        const page = await open(engine, variant);
        expect(await toUpdate(page), "ArrowDown reaches the footer's Update").toBe(true);
        await page.keyboard.press("Enter");
        await page.locator(".acpmux-quick-menu").waitFor({ state: "detached" });
        await page.close();
      });

      test(`${engine} ${variant}: in a short window the keyboard brings Update into view`, async () => {
        const page = await open(engine, variant, 260);
        expect(await toUpdate(page), "ArrowDown reaches the footer's Update").toBe(true);
        await atRest(page);
        const seen = await page.evaluate(() => {
          const popup = document.querySelector<HTMLElement>(".acpmux-quick-menu")!.getBoundingClientRect();
          const update = document.activeElement!.getBoundingClientRect();
          return {
            popup: { top: popup.top, bottom: popup.bottom },
            top: update.top,
            bottom: update.bottom,
            window: innerHeight,
          };
        });
        console.log(`::notice title=model-menu-update-footer (${engine} ${variant} short)::${JSON.stringify(seen)}`);
        expect(seen.top, "inside the menu").toBeGreaterThanOrEqual(seen.popup.top - 1);
        expect(seen.bottom, "inside the menu").toBeLessThanOrEqual(seen.popup.bottom + 1);
        expect(seen.top, "inside the window").toBeGreaterThanOrEqual(-1);
        expect(seen.bottom, "inside the window").toBeLessThanOrEqual(seen.window + 1);
        // One up is the list's last row: it scrolls into the list's visible box, above the footer.
        await page.keyboard.press("ArrowUp");
        await atRest(page);
        const last = await page.evaluate(() => {
          const popup = document.querySelector<HTMLElement>(".acpmux-quick-menu")!;
          const row = document.activeElement!;
          const view = (popup.querySelector(".acpmux-quick-body") ?? popup).getBoundingClientRect();
          const footer = popup.querySelector(".acpmux-quick-update")!.getBoundingClientRect();
          const rect = row.getBoundingClientRect();
          return {
            inFooter: row.closest(".acpmux-quick-update") !== null,
            top: rect.top,
            bottom: rect.bottom,
            view: { top: view.top, bottom: view.bottom },
            footerTop: footer.top,
          };
        });
        console.log(`::notice title=model-menu-update-footer (${engine} ${variant} last row)::${JSON.stringify(last)}`);
        expect(last.inFooter, "the row above Update is a list row").toBe(false);
        expect(last.top, "inside the list's visible box").toBeGreaterThanOrEqual(last.view.top - 1);
        expect(last.bottom, "inside the list's visible box").toBeLessThanOrEqual(last.view.bottom + 1);
        expect(last.bottom, "above the footer").toBeLessThanOrEqual(last.footerTop + 1);
        await page.close();
      });

      test(`${engine} ${variant}: Escape closes the menu with the update offered`, async () => {
        const page = await open(engine, variant);
        await page.keyboard.press("Escape");
        await page.locator(".acpmux-quick-menu").waitFor({ state: "detached" });
        await page.close();
      });
    }
  }
});
