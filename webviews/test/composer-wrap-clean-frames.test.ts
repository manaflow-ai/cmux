// cmux-web-test-timeout: 300
// l10n-allow-file: typed fixture text, not shipped UI.
// Lawrence 2026-11-15 (a 120 fps capture of the New Tab composer): "on newline, there is a frame of
// weirdness. guys we need to have better attention to detail." The field grows to its new line on a
// spring (composer/fieldGrowth.ts), and mid-motion its text is taller than its box. Two things then
// drew frames that were neither the old layout nor the new one:
//
// - the long-draft fade's marks (data-fade-top / data-fade-bottom from ui/scrollEdges.ts, drawn by
//   markdownField.css) read the overflow as "more draft past this edge" and faded a one- or
//   two-line field almost whole, so the text went dim for the motion's length;
// - a key typed while the field still moved (the letters after the one that wrapped): the engine's
//   own caret reveal scrolled the text up inside the box that was still a line short, and the
//   growth's retarget kept that scroll, so the first line jumped up and slid back.
//
// Every painted frame from the key until the field rests is read, in Chromium and WebKit, in the
// New Tab field and the chat composer, for a soft wrap, Shift-Return and the Backspace that takes the
// line back: no frame fades the text, the text's top stays on the field's top, and on New Tab the
// suggestions popover keeps its gap under the box in every frame.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

type Read = {
  /** The field moves (its growth animation runs). */
  moving: boolean;
  height: number;
  fade: string;
  scrollTop: number;
  /** The first line's top less the field's top (its padding when the text rests at the top). */
  textTop: number;
  /** New Tab: the suggestions popover's top less the composer anchor's bottom, else NaN. */
  rowsGap: number;
};

await requireBrowserLane("composer-wrap-clean-frames.test.ts", async () => {
  setDefaultTimeout(280_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][])
    if (await probeEngineOrSkip("composer-wrap-clean-frames", engine[0], engine[1])) engines.push(engine);
  if (engines.length === 0) return;

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "empty" } });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "idle" } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const surfaces = [
    { name: "New Tab", entry: "agent-pane.new-tab", variant: "empty", field: ".nt-field", anchor: ".nt-box" },
    { name: "chat composer", entry: "agent-pane.composer", variant: "idle", field: ".acpmux-md-field", anchor: "" },
  ];
  type Surface = (typeof surfaces)[number];

  const open = async (engine: string, surface: Surface) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 720, height: 640 }, deviceScaleFactor: 1 });
    await installPaintedFrames(page);
    // The field's growth runs at a tenth of its speed (as CDP's Animation.setPlaybackRate does in
    // composer-grow-no-thumb, in both engines here): the keys after the one that wraps always land
    // while the box is still about a line short, as on a busy Mac, not only when a runner is slow.
    await page.addInitScript(() => {
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (this: Element, ...args: Parameters<Element["animate"]>) {
        const animation = animate.apply(this, args);
        if (this.classList?.contains("acpmux-md-field")) animation.playbackRate = 0.1;
        return animation;
      };
    });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(surface.entry, { variant: surface.variant, frame: "component", width: 720, theme: "Apple System Colors" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    await page.locator(`${surface.field} .ProseMirror`).first().click();
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    await rest(page, surface);
    return page;
  };

  const rest = (page: Page, surface: Surface) =>
    page.waitForFunction(
      (selector) => document.querySelector<HTMLElement>(selector)!.getAnimations().length === 0,
      surface.field,
    );

  /** Starts reading every painted frame into `window.__reads`. */
  const startReads = (page: Page, surface: Surface) =>
    page.evaluate(
      ([fieldSelector, anchorSelector]) => {
        const w = window as unknown as { __reads: unknown[]; __stop?: () => void };
        w.__stop?.();
        w.__reads = [];
        w.__stop = window.cmuxAfterPaint(() => {
          const field = document.querySelector<HTMLElement>(fieldSelector!)!;
          const box = field.getBoundingClientRect();
          const first = field.querySelector(".ProseMirror > *");
          const anchor = anchorSelector ? document.querySelector<HTMLElement>(anchorSelector) : null;
          const rows = document.querySelector<HTMLElement>(".nt-popover");
          w.__reads.push({
            moving: field.getAnimations().length > 0,
            height: Math.round(box.height * 10) / 10,
            // An edge fade (markdownField.css) draws on the field's data-fade-top / data-fade-bottom
            // marks (ui/scrollEdges.ts). Read the marks, not the computed mask: headless engines
            // compute this mask's var() stops as "none" though a Mac's WebKit draws it.
            fade: `${field.hasAttribute("data-fade-top") ? "top " : ""}${field.hasAttribute("data-fade-bottom") ? "bottom" : ""}`,
            scrollTop: field.scrollTop,
            textTop: first ? Math.round((first.getBoundingClientRect().top - box.top) * 10) / 10 : Number.NaN,
            rowsGap:
              anchor && rows
                ? Math.round((rows.getBoundingClientRect().top - anchor.getBoundingClientRect().bottom) * 10) / 10
                : Number.NaN,
          });
          return w.__reads.length < 600;
        });
      },
      [surface.field, surface.anchor],
    );
  const takeReads = async (page: Page, surface: Surface) => {
    await rest(page, surface);
    await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => window.cmuxPaintFrame());
    return page.evaluate(() => {
      const w = window as unknown as { __reads: Read[]; __stop?: () => void };
      w.__stop?.();
      return w.__reads;
    });
  };

  /** Types words until the draft wraps onto a second line; returns the frames from that word's key. */
  const softWrap = async (page: Page, surface: Surface) => {
    const height = () => page.evaluate((s) => document.querySelector(s)!.getBoundingClientRect().height, surface.field);
    await page.keyboard.insertText("Please refactor the fetch helper");
    await rest(page, surface);
    const one = await height();
    for (let word = 0; word < 60; word++) {
      await startReads(page, surface);
      // One key a frame or so, as a person types: the keys after the one that wraps land mid-motion.
      await page.keyboard.type(" retry", { delay: 40 });
      const reads = await takeReads(page, surface);
      if ((await height()) > one + 1) return { reads, one };
    }
    throw new Error("the draft never wrapped");
  };

  const check = (label: string, reads: Read[], rested: Read) => {
    console.log(`WRAP_FRAMES ${label} ${JSON.stringify(reads)}`);
    expect(reads.length).toBeGreaterThan(0);
    for (const [index, read] of reads.entries()) {
      const where = `${label} frame ${index}: ${JSON.stringify(read)}`;
      // The text fits the height it lands on: nothing is past either edge, so nothing fades.
      expect(read.fade, where).toBe("");
      // The text's top rides the field's top: no caret reveal scrolls it up mid-motion.
      expect(read.scrollTop, where).toBe(0);
      expect(Math.abs(read.textTop - rested.textTop), where).toBeLessThanOrEqual(0.5);
      // The suggestions hang at the same gap under the box in every frame (none lags a frame).
      if (!Number.isNaN(rested.rowsGap) && !Number.isNaN(read.rowsGap))
        // Within a pixel: the popover's place is rounded to the device pixel, the box's bottom is not.
        expect(Math.abs(read.rowsGap - rested.rowsGap), where).toBeLessThanOrEqual(1);
    }
  };

  for (const [engine] of engines)
    for (const surface of surfaces)
      test(`${engine} ${surface.name}: a wrap, Shift-Return and the Backspace back draw no faded or scrolled frame`, async () => {
        const page = await open(engine, surface);
        try {
          const wrap = await softWrap(page, surface);
          const afterWrap = wrap.reads.at(-1)!;
          check(`${engine} ${surface.name} soft-wrap`, wrap.reads, afterWrap);
          expect(wrap.reads.some((read) => read.moving) || wrap.reads.length > 0).toBe(true);

          await startReads(page, surface);
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.type("and the 503 path", { delay: 40 });
          const newline = await takeReads(page, surface);
          check(`${engine} ${surface.name} shift-return`, newline, newline.at(-1)!);
          expect(newline.at(-1)!.height).toBeGreaterThan(afterWrap.height + 1);

          await page.keyboard.press("ControlOrMeta+A");
          await page.keyboard.press("Backspace");
          await rest(page, surface);
          await page.keyboard.insertText("Please refactor the fetch helper");
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.insertText("x");
          await rest(page, surface);
          await startReads(page, surface);
          await page.keyboard.press("Backspace");
          await page.keyboard.press("Backspace");
          const shrink = await takeReads(page, surface);
          check(`${engine} ${surface.name} backspace`, shrink, shrink.at(-1)!);
          expect(Math.abs(shrink.at(-1)!.height - wrap.one)).toBeLessThanOrEqual(1);
        } finally {
          await page.close();
        }
      });
});
