// l10n-allow-file: public transcript fixtures, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { GAP_KINDS, gapPair } from "../src/agent-session/acpmux/conversation/selectionGaps.fixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("transcript-gap-select-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, engine] of [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as const) {
      browsers.set(name, await engine.launch({ headless: true }));
    }
    if (process.env.CMUX_GAP_CAPTURE)
      await warmGalleryFrame(vite, "agent-pane.gutter-select", {
        browser: browsers.get("chromium"),
        params: { variant: "gaps-ready" },
      });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });
  const paint = (page: Page) =>
    page.evaluate(async () => {
      for (let left = 4; left > 0; left--) await window.cmuxPaintFrame();
    });
  const selected = (page: Page) => page.evaluate(() => window.getSelection()?.toString() ?? "");
  const drag = async (page: Page, from: { x: number; y: number }, to: { x: number; y: number }) => {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    await page.mouse.move(to.x, to.y, { steps: 6 });
    await paint(page);
    await page.mouse.up();
  };
  const open = async (name: string, above: (typeof GAP_KINDS)[number], below: (typeof GAP_KINDS)[number]) => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 900 }, reducedMotion: "reduce" });
    await installPaintedFrames(page);
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRawRows" in window);
    await page.evaluate(
      (rows) => (window as unknown as { __showRawRows(rows: unknown): void }).__showRawRows(rows),
      gapPair(above, below),
    );
    await page.waitForSelector('[data-row-id="after"]');
    for (const id of ["upper", "lower"]) {
      const toggle = page.locator(`[data-row-id="${id}"] .cv-tool.is-toggle`);
      if (await toggle.count()) await toggle.click();
    }
    await paint(page);
    return page;
  };
  const geometry = (page: Page) =>
    page.evaluate(() => {
      const textBox = (id: string) => {
        const row = document.querySelector<HTMLElement>(`[data-row-id="${id}"]`)!;
        const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.startsWith(`${id} keeper`)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rects = Array.from(range.getClientRects());
          if (!rects.length) continue;
          const first = rects[0]!,
            last = rects[rects.length - 1]!;
          return { top: first.top, bottom: last.bottom, x: first.left + 30, y: first.top + first.height / 2 };
        }
        throw new Error(`No visible text for ${id}`);
      };
      const upper = textBox("upper"),
        lower = textBox("lower"),
        after = textBox("after");
      const column = document.querySelector<HTMLElement>('[data-row-id="upper"]')!.getBoundingClientRect();
      return {
        upper,
        lower,
        after,
        gapY: (upper.bottom + lower.top) / 2,
        center: (column.left + column.right) / 2,
        left: column.left / 2,
        right: (column.right + innerWidth - 16) / 2,
      };
    });
  for (const name of ["chromium", "webkit"]) {
    for (const above of GAP_KINDS)
      for (const below of GAP_KINDS) {
        test(`${name}: ${above} to ${below} gap and side gutters restart at the nearest caret`, async () => {
          const page = await open(name, above, below);
          const box = await geometry(page);
          expect(box.lower.top).toBeGreaterThan(box.upper.bottom);
          for (const x of [box.center, box.left, box.right]) {
            await drag(page, { x, y: box.gapY }, box.after);
            expect((await selected(page)).length).toBeGreaterThan(0);
            const anchor = await page.evaluate(() => {
              const s = getSelection()!;
              return {
                row: s.anchorNode?.parentElement?.closest(".acpmux-row")?.getAttribute("data-row-id"),
                offset: s.anchorOffset,
                length: s.anchorNode?.textContent?.length,
              };
            });
            expect(anchor.row).toBe("upper");
            expect(anchor.offset).toBe(anchor.length);
            // Restart from an existing selection, then a plain gap click must clear it.
            await drag(page, { x, y: box.gapY }, box.lower);
            expect((await selected(page)).length).toBeGreaterThan(0);
            await page.mouse.click(x, box.gapY);
            expect(await selected(page)).toBe("");
          }
          // A point nearer the next row starts at its first caret, rather than at the preceding end.
          await drag(page, { x: box.center, y: box.lower.top - 0.5 }, box.after);
          expect(
            await page.evaluate(() =>
              getSelection()?.anchorNode?.parentElement?.closest(".acpmux-row")?.getAttribute("data-row-id"),
            ),
          ).toBe("lower");
          expect(await page.evaluate(() => getSelection()?.anchorOffset)).toBe(0);
          await page.close();
        });
      }
    test(`${name}: control presses, control drags, and text presses retain native ownership`, async () => {
      const page = await open(name, "tool", "prompt");
      await page.evaluate(() => {
        const row = document.querySelector('[data-row-id="upper"]')!;
        const wrap = document.createElement("div");
        wrap.id = "selection-controls";
        wrap.innerHTML =
          '<button>Attach file</button><a href="#fixture">Harbour link</a><span role="button" tabindex="0">Sender chip</span><input aria-label="Fixture field"><span draggable="true">Drag file</span>';
        row.append(wrap);
        wrap.addEventListener("pointerdown", (event) => (wrap.dataset.prevented = String(event.defaultPrevented)));
      });
      const end = (await geometry(page)).after;
      for (const selector of ["button", "a", '[role="button"]', "input", '[draggable="true"]']) {
        const control = page.locator(`#selection-controls ${selector}`);
        const box = (await control.boundingBox())!;
        await drag(page, { x: box.x + box.width / 2, y: box.y + box.height / 2 }, end);
        expect(await page.locator("#selection-controls").getAttribute("data-prevented")).toBe("false");
      }
      const toggle = page.locator('[data-row-id="upper"] .cv-tool.is-toggle');
      await toggle.click();
      expect(await toggle.getAttribute("aria-expanded")).toBe("false");
      await page.evaluate(() => {
        document.querySelector('[data-row-id="lower"] .cv-user__text')!.addEventListener("pointerdown", (event) => {
          document.body.dataset.textPrevented = String(event.defaultPrevented);
        });
      });
      const prompt = (await page.locator('[data-row-id="lower"] .cv-user__text').boundingBox())!;
      await drag(page, { x: prompt.x + 30, y: prompt.y + 8 }, end);
      expect(await page.locator("body").getAttribute("data-text-prevented")).toBe("false");
      expect((await selected(page)).length).toBeGreaterThan(0);
      await page.close();
    });
  }
  if (process.env.CMUX_GAP_CAPTURE)
    test("public gallery before/after capture", async () => {
      const label = process.env.CMUX_GAP_CAPTURE!;
      const page = await browsers
        .get("chromium")!
        .newPage({ viewport: { width: 1280, height: 560 }, reducedMotion: "reduce" });
      await installPaintedFrames(page);
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.gutter-select", { variant: "gaps-ready", width: 1280, height: 560, frame: "component", theme: "Apple System Colors", locale: "en" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator('[data-row-id="upper"] .cv-tool.is-toggle').click();
      await paint(page);
      const box = await geometry(page);
      await drag(page, { x: box.center, y: box.gapY }, box.after);
      const hasSelection = (await selected(page)).length > 0;
      if (label === "after") expect(hasSelection).toBe(true);
      console.log(
        `GAP_GALLERY_CAPTURE_${label}=${(await page.locator(".acpmux-shell").screenshot()).toString("base64")}`,
      );
      console.log(
        `GAP_GALLERY_META=${JSON.stringify({ label, selection: hasSelection, viewport: "1280x560", theme: "Apple System Colors", locale: "en", engine: `Chromium ${browsers.get("chromium")!.version()}`, fixture: "agent-pane.gutter-select/gaps-ready" })}`,
      );
      await page.close();
    });
});
