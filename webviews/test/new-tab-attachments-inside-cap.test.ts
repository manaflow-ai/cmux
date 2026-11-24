// cmux-web-test-timeout: 300
// Leo, 2026-11-23 (ask-525a5e502a), paraphrased: adding attachments must not make the composer even
// taller; this goes for the GUI chat too; have them within the top part of the composer, the inner
// area grows at the top, no shift, nothing. The chat pane got it in #53583
// (composer-attachments-inside-cap.test.ts); this holds the New Tab page to the same: its strip sits
// inside the top of the box and the field takes the strip's band out of its max height (newtab/
// screen.css for NewTabScreen, styles.css and composerAttachments.css for the Classic NewTabPage):
//   - at the cap (a draft past the field's max height), adding 1, 2 and 5 attachments and removing
//     them leaves the box's height, top and bottom where they were;
//   - the strip is the box's first row: it sits above the field, inside the box.
// The pane's dev entry as a New Tab page on the in-page mock transport, in Chromium; CI fails the
// file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Box = { height: number; top: number; bottom: number };
type ImageWindow = Window & { __images?: File[] };

const TEMPLATES = {
  screen: { box: ".nt-box", field: ".nt-field.acpmux-md-field", editor: ".nt-field [contenteditable=true]" },
  classic: {
    box: ".acpmux-newtab-box",
    field: ".acpmux-newtab-field.acpmux-md-field",
    editor: ".acpmux-newtab-field [contenteditable=true]",
  },
} as const;
type Template = keyof typeof TEMPLATES;

await requireBrowserLane("new-tab-attachments-inside-cap.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    if (process.env.GITHUB_ACTIONS === "true")
      throw new Error("new-tab-attachments-inside-cap: chromium did not launch");
    console.warn("new-tab-attachments-inside-cap: skipping (run `bunx playwright install chromium`)");
    describe.skip("New Tab attachments inside the cap", () => test("chromium", () => {}));
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

  /// A New Tab page as Cmd-T opens one, in Settings' strip view (every attachment in the strip).
  async function newTab(template: Template): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 1000, height: 1000 } });
    await page.addInitScript((classic) => {
      const newTab = {
        kind: "agent",
        hotkeys: {},
        home: "/Users/you",
        projects: [],
        ...(classic ? { template: "classic" } : {}),
      };
      Object.assign(window, {
        __cmuxNewTabContext: newTab,
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, newTab }),
        },
      });
    }, template === "classic");
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(TEMPLATES[template].editor).waitFor();
    await page.evaluate(() =>
      (window as Window & { cmuxAcpmuxComposer?: (value: unknown) => void }).cmuxAcpmuxComposer?.({
        attachmentView: "strip",
      }),
    );
    await page.locator(TEMPLATES[template].editor).click();
    return page;
  }

  const box = (page: Page, template: Template) =>
    page.evaluate((selector): Box => {
      const { height, top, bottom } = document.querySelector(selector)!.getBoundingClientRect();
      return { height, top, bottom };
    }, TEMPLATES[template].box);

  /// Until the box's height has held for 20 frames, so a measurement never reads a layout on its way.
  const settle = (page: Page, template: Template) =>
    page.evaluate(
      (selector) =>
        new Promise<void>((resolve) => {
          const card = document.querySelector(selector)!;
          let last = -1;
          let still = 0;
          let frames = 0;
          const step = () => {
            const height = card.getBoundingClientRect().height;
            still = Math.abs(height - last) < 0.01 ? still + 1 : 0;
            last = height;
            frames += 1;
            if (still >= 20 || frames > 600) resolve();
            // raf-read: the box's height each frame until it holds.
            else requestAnimationFrame(step);
          };
          // raf-read: the same wait, from the next frame.
          requestAnimationFrame(step);
        }),
      TEMPLATES[template].box,
    );

  /// Pastes `count` images, one paste each, and waits for every tile in the strip.
  async function attach(page: Page, template: Template, count: number) {
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
    const before = await page.locator(".acpmux-attachments .acpmux-attachment").count();
    await page.evaluate((editor) => {
      const field = document.querySelector(editor)!;
      for (const file of (window as ImageWindow).__images!) {
        const data = new DataTransfer();
        data.items.add(file);
        const paste = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
        if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
        field.dispatchEvent(paste);
      }
    }, TEMPLATES[template].editor);
    await page.waitForFunction(
      (want) => document.querySelectorAll(".acpmux-attachments .acpmux-attachment").length >= want,
      before + count,
      { timeout: 20_000 },
    );
    await settle(page, template);
  }

  async function clear(page: Page, template: Template) {
    for (let guard = 0; guard < 20; guard += 1) {
      const remove = page.locator(".acpmux-attachments .acpmux-attachment-remove").first();
      if (!(await remove.count())) break;
      await remove.click({ force: true });
    }
    await page.waitForSelector(".acpmux-attachments", { state: "detached", timeout: 10_000 });
    await settle(page, template);
  }

  for (const template of Object.keys(TEMPLATES) as Template[]) {
    const { box: boxSelector, field: fieldSelector } = TEMPLATES[template];
    test(`${template}: at the cap, adding 1, 2 and 5 attachments moves nothing, and the strip heads the box`, async () => {
      const page = await newTab(template);
      const lines = Array.from({ length: 60 }, (_, line) => `line ${line} of a long draft`).join("\n");
      await page.keyboard.insertText(lines);
      await settle(page, template);
      const capped = await page.evaluate((selector) => {
        const md = document.querySelector(selector)!;
        return {
          scroll: md.scrollHeight,
          client: md.clientHeight,
          height: md.getBoundingClientRect().height,
          max: parseFloat(getComputedStyle(md).maxHeight),
        };
      }, fieldSelector);
      // A draft past the cap: the field scrolls inside itself and stands at its max height.
      expect(capped.scroll).toBeGreaterThan(capped.client + 40);
      expect(Math.abs(capped.height - capped.max)).toBeLessThanOrEqual(1);
      const rest = await box(page, template);
      for (const count of [1, 2, 5]) {
        await attach(page, template, count);
        const placed = await page.evaluate(
          ({ boxSelector, fieldSelector }) => {
            const card = document.querySelector(boxSelector)!.getBoundingClientRect();
            const strip = document.querySelector(".acpmux-attachments")!.getBoundingClientRect();
            const field = document.querySelector(fieldSelector)!.getBoundingClientRect();
            return { card: card.top, strip: strip.top, stripBottom: strip.bottom, field: field.top };
          },
          { boxSelector, fieldSelector },
        );
        console.log(`${template} +${count}`, JSON.stringify(placed));
        // Inside the top of the box, above the field.
        expect(placed.strip).toBeGreaterThanOrEqual(placed.card - 0.5);
        expect(placed.stripBottom).toBeLessThanOrEqual(placed.field + 0.5);
        const now = await box(page, template);
        expect(Math.abs(now.height - rest.height)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(now.top - rest.top)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(now.bottom - rest.bottom)).toBeLessThanOrEqual(0.5);
        await clear(page, template);
        const back = await box(page, template);
        expect(Math.abs(back.height - rest.height)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(back.top - rest.top)).toBeLessThanOrEqual(0.5);
      }
      await page.close();
    });
  }
});
