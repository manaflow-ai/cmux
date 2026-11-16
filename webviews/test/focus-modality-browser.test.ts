// FOCUS-RING in real Chromium and WebKit (src/ui/focusModality.ts). Leo, 2026-11-06: "i need the
// focus ring to STOP FIRING SO OFTEN AND TO BE ABLE TO CANCEL IT JUST GETS STUCK IN THESE
// SITUATIONS". Through the desktop layer and the build-gated stylesheets:
// - only a Tab that moves focus draws the ring; a click, a shortcut or a later code focus draws none;
// - a press, Escape or a pointer move takes it away, and focus stays;
// - the chat composer's rim follows the same rule (a click in the prompt does not light it).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { focusByKey } from "./support/focusByKey";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("focus-modality-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const HARNESS = "/test/browser/focus-modality.html";
  let vite: Awaited<ReturnType<typeof import("vite").createServer>> | undefined;
  beforeAll(async () => {
    const { createServer } = await import("vite");
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, HARNESS);
  });
  afterAll(async () => {
    await vite?.close();
  });

  /** What a focus ring can change on a control: the shared outline, or the agent pane's pill
   * (agent-session/shared/styles.css paints a background image in its place). */
  const look = (page: Page, id: string) =>
    page.evaluate((id) => {
      const style = getComputedStyle(document.getElementById(id)!);
      return [style.outlineStyle, style.outlineColor, style.backgroundImage, style.boxShadow].join(" | ");
    }, id);
  /** Whether `id` draws a ring now: its look differs from its resting look (taken unfocused). */
  const resting = new Map<Page, Record<string, string>>();
  const ringOf = async (page: Page, id: string) => (await look(page, id)) !== resting.get(page)![id];
  const modality = (page: Page) => page.evaluate(() => document.documentElement.dataset.focusModality);
  const active = (page: Page) => page.evaluate(() => document.activeElement?.id);
  const rim = (page: Page) => page.evaluate(() => getComputedStyle(document.getElementById("composer")!).boxShadow);

  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });
      async function open(): Promise<Page> {
        const page = await browser!.newPage({ viewport: { width: 480, height: 360 } });
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}${HARNESS}`);
        await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
        resting.set(page, { a: await look(page, "a"), b: await look(page, "b") });
        return page;
      }

      test("a Tab earns the ring; a click on a control draws none", async () => {
        const page = await open();
        await focusByKey(page, "#a");
        expect(await ringOf(page, "a")).toBe(true);
        await page.click("#b");
        expect(await active(page)).toBe("b");
        expect(await ringOf(page, "b")).toBe(false);
        await page.close();
      });

      test("a shortcut that focuses from code, or code focus later, draws none", async () => {
        const page = await open();
        await page.keyboard.press("Meta+k");
        expect(await active(page)).toBe("b");
        expect(await ringOf(page, "b")).toBe(false);
        await focusByKey(page, "#a");
        // fixed-wait: the point is a focus move after the key's earn window (EARN_WINDOW_MS) has passed.
        await page.waitForTimeout(300);
        await page.evaluate(() => document.getElementById("b")!.focus());
        expect(await ringOf(page, "b")).toBe(false);
        await page.close();
      });

      test("a code focus two frames after a Tab draws none (a key the app's router took, a late reply)", async () => {
        const page = await open();
        await focusByKey(page, "#a");
        await page.evaluate(
          () =>
            new Promise((done) =>
              requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(done))),
            ),
        );
        await page.evaluate(() => document.getElementById("b")!.focus());
        expect(await active(page)).toBe("b");
        expect(await ringOf(page, "b")).toBe(false);
        await page.close();
      });

      for (const [how, cancel] of [
        ["Escape", (page: Page) => page.keyboard.press("Escape")],
        [
          "a pointer move",
          async (page: Page) => {
            await page.mouse.move(300, 300);
            await page.mouse.move(340, 320, { steps: 4 });
          },
        ],
        ["a press elsewhere", (page: Page) => page.mouse.click(400, 340)],
      ] as [string, (page: Page) => Promise<void>][]) {
        test(`${how} takes the ring away and focus stays`, async () => {
          const page = await open();
          await focusByKey(page, "#a");
          expect(await ringOf(page, "a")).toBe(true);
          await cancel(page);
          expect(await modality(page)).toBe("pointer");
          expect(await ringOf(page, "a")).toBe(false);
          if (how !== "a press elsewhere") expect(await active(page)).toBe("a");
          await page.close();
        });
      }

      test("a shell composer keeps its own rim on a Tab: the gate adds no weight", async () => {
        const page = await open();
        const ringVar = () =>
          page.evaluate(() =>
            getComputedStyle(document.getElementById("composer")!).getPropertyValue("--acpmux-card-ring").trim(),
          );
        await page.evaluate(() => document.querySelector(".acpmux-composer")!.setAttribute("data-shell", ""));
        const shellRim = await ringVar();
        await focusByKey(page, "#field");
        expect(await modality(page)).toBe("keyboard");
        expect(await ringVar()).toBe(shellRim);
        await page.close();
      });

      test("the composer's rim stays at rest for a click in the prompt, and lights for a Tab", async () => {
        const page = await open();
        const resting = await rim(page);
        await page.click("#field");
        expect(await active(page)).toBe("field");
        expect(await rim(page)).toBe(resting);
        await page.mouse.click(400, 340);
        await focusByKey(page, "#field");
        expect(await rim(page)).not.toBe(resting);
        await page.keyboard.press("Escape");
        expect(await rim(page)).toBe(resting);
        await page.close();
      });
    });
  }
});
