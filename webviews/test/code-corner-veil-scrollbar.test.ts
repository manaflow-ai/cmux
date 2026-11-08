// cmux-web-test-timeout: 120
// An unlabeled highlighted code card keeps its horizontal scrollbar visible under the corner veil.
// Pierre hangs that scrollbar below the body's box into the card's bottom inset
// (highlightedCodeModel.ts `codeUnsafeCSS`, 6 px in WebKit), and the veil masks the body
// (conversation.css `--cv-code-corner-veil`): a mask painted only over the body's own lines cut the
// scrollbar off at rest and on hover (cross-model review of #37521). At rest and hovered, the
// mask's painted area must reach the scrollbar's bottom, and the lane must look the same as it does
// with no mask at all.
//
// It renders `agent-pane.code-toolbar-buttons` (the `highlighted` surface, Pierre on the main
// thread) on the gallery stage in Chromium and WebKit, where the lane is real.
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/code-corner-veil-scrollbar.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("code-corner-veil-scrollbar.test.ts", async () => {
  const ENTRY = "agent-pane.code-toolbar-buttons";
  setDefaultTimeout(90_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`code-corner-veil-scrollbar: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("code corner veil scrollbar", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant: "highlighted-rest", frame: "component", width: 680, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, [ENTRY], { browser: browsers.get("chromium") ?? browsers.values().next().value });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** Resolves once nothing on the page is easing (a looping animation never ends). */
  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );

  const open = async (name: string): Promise<Page> => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 680, height: 320 } });
    for (;;) {
      await page.goto(stageURL());
      try {
        await page.waitForFunction(() => document.querySelector('[data-gallery-pierre="painted"]'), undefined, {
          timeout: 30_000,
        });
        break;
      } catch (error) {
        // The first load can run Vite's dependency optimizer and reload mid-compile.
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.mouse.move(1, 1);
    await eased(page);
    return page;
  };

  const BODY = "[data-gallery-pierre] .cv-codeblock__body";

  /** The scroller in Pierre's shadow root, its scrollbar lane, and the box the body's mask paints. */
  const geometry = (page: Page) =>
    page.evaluate((selector) => {
      const body = document.querySelector<HTMLElement>(selector)!;
      const scroller = body.shadowRoot!.querySelector<HTMLElement>("[data-code]")!;
      const style = getComputedStyle(body);
      const mask = style.maskImage || style.getPropertyValue("-webkit-mask-image");
      const clip = style.maskClip || style.getPropertyValue("-webkit-mask-clip");
      const box = body.getBoundingClientRect();
      const n = (value: string) => Number.parseFloat(value) || 0;
      // The mask's painting area: the body's border box, or its padding or content box.
      const inset =
        clip === "content-box"
          ? n(style.borderBottomWidth) + n(style.paddingBottom)
          : clip === "padding-box"
            ? n(style.borderBottomWidth)
            : 0;
      const bar = scroller.getBoundingClientRect();
      return {
        masked: mask !== "none" && mask !== "",
        maskBottom: box.bottom - inset,
        barBottom: bar.bottom,
        lane: scroller.offsetHeight - scroller.clientHeight,
        overflows: scroller.scrollWidth > scroller.clientWidth,
        x: bar.left,
        width: bar.width,
      };
    }, BODY);

  /** The scrollbar lane's pixels, as a PNG. */
  const lanePixels = async (page: Page, at: Awaited<ReturnType<typeof geometry>>) =>
    page.screenshot({
      clip: { x: at.x, y: at.barBottom - Math.max(at.lane, 1), width: at.width, height: Math.max(at.lane, 1) },
    });

  /** The largest channel difference between two same-sized PNGs. */
  const spread = (page: Page, a: Buffer, b: Buffer) =>
    page.evaluate(
      async ([a, b]) => {
        const read = async (data: string) => {
          const image = new Image();
          image.src = `data:image/png;base64,${data}`;
          await image.decode();
          const canvas = document.createElement("canvas");
          canvas.width = image.width;
          canvas.height = image.height;
          const context = canvas.getContext("2d")!;
          context.drawImage(image, 0, 0);
          return context.getImageData(0, 0, image.width, image.height).data;
        };
        const [x, y] = [await read(a!), await read(b!)];
        let most = 0;
        for (let i = 0; i < x.length; i++) if (i % 4 !== 3) most = Math.max(most, Math.abs(x[i]! - y[i]!));
        return most;
      },
      [a.toString("base64"), b.toString("base64")],
    );

  /** How far the reddest pixel of a PNG leans to red (its red less its other channels' larger). */
  const reddest = (page: Page, png: Buffer) =>
    page.evaluate(async (data) => {
      const image = new Image();
      image.src = `data:image/png;base64,${data}`;
      await image.decode();
      const canvas = document.createElement("canvas");
      canvas.width = image.width;
      canvas.height = image.height;
      const context = canvas.getContext("2d")!;
      context.drawImage(image, 0, 0);
      const pixels = context.getImageData(0, 0, image.width, image.height).data;
      let most = 0;
      for (let i = 0; i < pixels.length; i += 4)
        most = Math.max(most, pixels[i]! - Math.max(pixels[i + 1]!, pixels[i + 2]!));
      return most;
    }, png.toString("base64"));

  for (const [name] of engines)
    for (const state of ["rest", "hover"] as const)
      test(`${name}, ${state}: the veil leaves an overflowing highlighted card's scrollbar painted`, async () => {
        const page = await open(name);
        if (state === "hover") {
          // On the card's text, away from the corner glyphs.
          const card = (await page.locator("[data-gallery-pierre]").boundingBox())!;
          await page.mouse.move(card.x + 40, card.y + card.height / 2);
          await eased(page);
        }
        // A thumb that shows: Pierre's is clear until its card is hovered, and faint then.
        await page.evaluate((selector) => {
          const style = document.createElement("style");
          style.textContent = "[data-code]::-webkit-scrollbar-thumb { background-color: #f00 !important; }";
          document.querySelector(selector)!.shadowRoot!.append(style);
        }, BODY);
        await eased(page);
        const at = await geometry(page);
        console.log(`code-corner-veil-scrollbar ${name} ${state}: ${JSON.stringify(at)}`);
        expect(at.overflows, "the first line runs past the card").toBe(true);
        if (name === "webkit") expect(at.lane, "WebKit keeps a scrollbar lane").toBeGreaterThan(0);
        // The lane looks as it does with no mask at all, the red thumb in it where the engine has one.
        const veiled = await lanePixels(page, at);
        if (at.lane > 0) expect(await reddest(page, veiled), "the scrollbar's thumb shows").toBeGreaterThan(120);
        await page.addStyleTag({
          content: `${BODY} { mask-image: none !important; -webkit-mask-image: none !important; }`,
        });
        await eased(page);
        const bare = await lanePixels(page, at);
        const differs = await spread(page, veiled, bare);
        console.log(`code-corner-veil-scrollbar ${name} ${state}: lane spread ${differs}`);
        expect(differs, "the scrollbar lane is not masked").toBeLessThanOrEqual(2);
        if (at.masked)
          expect(at.barBottom, "the mask paints down to the scrollbar's bottom").toBeLessThanOrEqual(
            at.maskBottom + 0.5,
          );
        await page.close();
      });
});
