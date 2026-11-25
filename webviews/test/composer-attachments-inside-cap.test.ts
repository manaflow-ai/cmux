// cmux-web-test-timeout: 240
// Leo, 2026-11-23 (ask-525a5e502a), paraphrased: adding attachments must not make the composer even
// taller; have them within the top part of the composer, the inner area grows at the top, no shift,
// nothing. The strip (Attachments at Top) sits inside the top of the card and takes its height out
// of the prompt's max height (composerAttachments.css --acpmux-attach-band, markdownField.css):
//   - at the cap (a draft past the prompt's max height), adding 1, 2 and 5 attachments and removing
//     them leaves the card's height and its top edge where they were, to the pixel;
//   - at a one-line draft the card grows by at most one tile's band, the same for 1, 2 or 5 (one row
//     that scrolls sideways), and returns to its height when they go;
//   - every arm of the strip-size experiment (composer/attachStrip.experiment.ts) holds the cap.
// The page is the pane's dev entry with the in-page mock transport, in Chromium; CI fails the file
// when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

type Box = { height: number; top: number; bottom: number };
type ImageWindow = Window & { __images?: File[] };

await requireBrowserLane("composer-attachments-inside-cap.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    if (process.env.GITHUB_ACTIONS === "true")
      throw new Error("composer-attachments-inside-cap: chromium did not launch");
    console.warn("composer-attachments-inside-cap: skipping (run `bunx playwright install chromium`)");
    describe.skip("attachments inside the composer's cap", () => test("chromium", () => {}));
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

  async function stage(arm?: string): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    await page.addInitScript((arm) => {
      if (arm) localStorage.setItem("cmux.experiments", JSON.stringify({ "composer-attach-strip-size": arm }));
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    }, arm);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.locator(COMPOSER_EDITOR).click();
    // Attachments at Top, from the prompt's own right-click menu (composer-field-menu.test.ts).
    await page.evaluate(() => {
      const field = document.querySelector(".acpmux-md")!;
      const box = field.getBoundingClientRect();
      field.dispatchEvent(
        new MouseEvent("contextmenu", {
          bubbles: true,
          cancelable: true,
          clientX: box.left + 40,
          clientY: box.top + 12,
        }),
      );
    });
    await page
      .locator(".ui-context-menu [role=menuitem], .ui-context-menu [role=menuitemcheckbox]", {
        hasText: "Attachments at Top",
      })
      .click();
    await page.waitForSelector(".ui-context-menu", { state: "detached" });
    await page.waitForFunction(
      () => document.querySelector(".acpmux-composer-box")?.getAttribute("data-attachment-view") === "strip",
    );
    if (arm) expect(await page.locator(".acpmux-composer-box").getAttribute("data-attach-size")).toBe(arm);
    await page.locator(COMPOSER_EDITOR).click();
    return page;
  }

  /// What the card is made of, logged when a case runs: the strip, the prompt and its cap (the
  /// numbers a failure needs to be read from the fleet's log).
  const probe = (page: Page, label: string) =>
    page
      .evaluate(() => {
        const read = (selector: string) => {
          const node = document.querySelector(selector) as HTMLElement | null;
          if (!node) return null;
          const style = getComputedStyle(node);
          return {
            h: node.getBoundingClientRect().height,
            maxH: style.maxHeight,
            minH: style.minHeight,
            band: style.getPropertyValue("--acpmux-attach-band"),
            attachH: style.getPropertyValue("--acpmux-attach-height"),
            pad: style.paddingTop,
          };
        };
        const box = document.querySelector(".acpmux-composer-box")!;
        return {
          box: read(".acpmux-composer-box"),
          strip: read(".acpmux-attachments"),
          tiles: [...document.querySelectorAll(".acpmux-attachments > *")].map((tile) => [
            tile.className,
            Math.round(tile.getBoundingClientRect().height),
          ]),
          field: read(".acpmux-md-field"),
          menu: read(".acpmux-composer-field-menu"),
          kids: [...box.children].map((child) => [child.className, Math.round(child.getBoundingClientRect().height)]),
          inline: document.querySelectorAll(".acpmux-md-inline").length,
          text: (document.querySelector(".acpmux-md") as HTMLElement).innerText.length,
        };
      })
      .then((value) => console.log(`probe ${label}`, JSON.stringify(value)));

  const box = (page: Page) =>
    page.evaluate((): Box => {
      const { height, top, bottom } = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      return { height, top, bottom };
    });

  /// Until the card's height has held for 20 frames (the prompt lays a long draft out over several),
  /// so a measurement never reads a layout still on its way.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const card = document.querySelector(".acpmux-composer-box")!;
          let last = -1;
          let still = 0;
          let frames = 0;
          const step = () => {
            const height = card.getBoundingClientRect().height;
            still = Math.abs(height - last) < 0.01 ? still + 1 : 0;
            last = height;
            frames += 1;
            if (still >= 20 || frames > 600) resolve();
            // raf-read: the card's height each frame until it holds.
            else requestAnimationFrame(step);
          };
          // raf-read: the same wait, from the next frame.
          requestAnimationFrame(step);
        }),
    );

  async function makeImages(page: Page, count: number) {
    await page.evaluate(async (count) => {
      const files: File[] = [];
      for (let index = 0; index < count; index += 1) {
        const canvas = document.createElement("canvas");
        canvas.width = 640;
        canvas.height = 400;
        const context = canvas.getContext("2d")!;
        context.fillStyle = `hsl(${index * 60} 40% 40%)`;
        context.fillRect(0, 0, 640, 400);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
        files.push(new File([blob], `shot-${index}.png`, { type: "image/png" }));
      }
      (window as ImageWindow).__images = files;
    }, count);
  }

  /// Pastes `count` images, one paste each, and waits for every tile to load in the strip.
  async function attach(page: Page, count: number) {
    await makeImages(page, count);
    const before = await page.locator(".acpmux-attachments .acpmux-attachment").count();
    await page.evaluate((prompt) => {
      const field = document.querySelector(prompt)!;
      for (const file of (window as ImageWindow).__images!) {
        const data = new DataTransfer();
        data.items.add(file);
        const paste = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
        if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
        field.dispatchEvent(paste);
      }
    }, COMPOSER_EDITOR);
    await page.waitForFunction(
      (want) => document.querySelectorAll(".acpmux-attachments .acpmux-attachment").length >= want,
      before + count,
      { timeout: 20_000 },
    );
    await settle(page);
  }

  /// Removes every attachment with its × and waits for the strip to go.
  async function clear(page: Page) {
    for (let guard = 0; guard < 20; guard += 1) {
      const remove = page.locator(".acpmux-attachments .acpmux-attachment-remove").first();
      if (!(await remove.count())) break;
      await remove.click({ force: true });
    }
    await page.waitForSelector(".acpmux-attachments", { state: "detached", timeout: 10_000 });
    await settle(page);
  }

  async function capDraft(page: Page) {
    const lines = Array.from({ length: 60 }, (_, line) => `line ${line} of a long draft`).join("\n");
    await page.keyboard.insertText(lines);
    await settle(page);
    const field = await page.evaluate(() => {
      const md = document.querySelector(".acpmux-md-field")!;
      return { scroll: md.scrollHeight, client: md.clientHeight };
    });
    // A draft past the cap: the prompt scrolls inside itself and stands at its max height.
    expect(field.scroll).toBeGreaterThan(field.client + 40);
    const capped = await page.evaluate(() => {
      const md = document.querySelector(".acpmux-md-field")!;
      return { height: md.getBoundingClientRect().height, max: parseFloat(getComputedStyle(md).maxHeight) };
    });
    expect(Math.abs(capped.height - capped.max)).toBeLessThanOrEqual(1);
  }

  for (const arm of [undefined, "tiles", "compact", "chips"] as const) {
    const name = arm ?? "default arm";
    test(`${name}: at the cap, adding 1, 2 and 5 attachments moves nothing`, async () => {
      const page = await stage(arm);
      await capDraft(page);
      const rest = await box(page);
      await probe(page, `${name} cap rest`);
      for (const count of [1, 2, 5]) {
        await attach(page, count);
        await probe(page, `${name} cap +${count}`);
        const now = await box(page);
        expect(Math.abs(now.height - rest.height)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(now.top - rest.top)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(now.bottom - rest.bottom)).toBeLessThanOrEqual(0.5);
        await clear(page);
        const back = await box(page);
        expect(Math.abs(back.height - rest.height)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(back.top - rest.top)).toBeLessThanOrEqual(0.5);
      }
      await page.close();
    });
  }

  test("a one-line draft grows by one band at most, the same for 1, 2 and 5, and returns", async () => {
    const page = await stage();
    await page.keyboard.insertText("one line");
    await settle(page);
    const rest = await box(page);
    await probe(page, "line rest");
    const grown: number[] = [];
    for (const count of [1, 2, 5]) {
      await attach(page, count);
      const now = await box(page);
      grown.push(now.height - rest.height);
      // The bottom edge stays put: the card grows at its top.
      expect(Math.abs(now.bottom - rest.bottom)).toBeLessThanOrEqual(0.5);
      await clear(page);
      await probe(page, `line cleared after ${count}`);
      expect(Math.abs((await box(page)).height - rest.height)).toBeLessThanOrEqual(0.5);
    }
    // A 64 px tile and its 8 px top inset, less the prompt's dropped top inset (13.625 to 6 px at
    // the default chrome size): 64.375 px, measured on the fleet (run 45394755450).
    for (const growth of grown) expect(growth).toBeLessThanOrEqual(64.5);
    expect(Math.max(...grown) - Math.min(...grown)).toBeLessThanOrEqual(0.5);
    await page.close();
  });
});
